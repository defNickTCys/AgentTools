function Get-AgentToolsProcessTreeType {
    # Retorna o tipo .NET versionado ProcessTree carregado para a versão atual do módulo.
    $ns = if ($script:AgentToolsTypeNamespace) { $script:AgentToolsTypeNamespace } else { 'AgentTools.V1_1_0' }
    return ("$ns.ProcessTree" -as [type])
}

function Initialize-AgentToolsProcessTree {
    # Compila sob demanda o snapshot Win32 da árvore de processos filhos com validação GetProcessTimes (sem carregar no import).
    if ($null -ne (Get-AgentToolsProcessTreeType)) { return $true }
    $ns = if ($script:AgentToolsTypeNamespace) { $script:AgentToolsTypeNamespace } else { 'AgentTools.V1_1_0' }
    $src = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using ComTypes = System.Runtime.InteropServices.ComTypes;

namespace $ns {
    public static class ProcessTree {
        private const uint TH32CS_SNAPPROCESS = 0x00000002;
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        private struct DescendantInfo {
            public int Pid;
            public string Name;
            public long CreationTime;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32 {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool Process32FirstW(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool Process32NextW(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(
            IntPtr hProcess,
            out ComTypes.FILETIME lpCreationTime,
            out ComTypes.FILETIME lpExitTime,
            out ComTypes.FILETIME lpKernelTime,
            out ComTypes.FILETIME lpUserTime);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        private static long FileTimeToInt64(ComTypes.FILETIME ft) {
            return ((long)(uint)ft.dwHighDateTime << 32) | (uint)ft.dwLowDateTime;
        }

        private static bool TryGetCreationTimeFromHandle(IntPtr handle, out long creationTime) {
            creationTime = 0;
            if (handle == IntPtr.Zero) return false;
            if (GetProcessTimes(handle, out var ct, out _, out _, out _)) {
                creationTime = FileTimeToInt64(ct);
                return creationTime > 0;
            }
            return false;
        }

        public static long GetProcessCreationTime(int pid) {
            if (pid <= 0) return 0;
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return 0;
            try {
                return TryGetCreationTimeFromHandle(h, out long ct) ? ct : 0;
            } finally {
                CloseHandle(h);
            }
        }

        public static bool TryKillVerified(int pid, long expectedCreationTime) {
            if (pid <= 0 || expectedCreationTime <= 0) return false;
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, false, pid);
            if (h == IntPtr.Zero) return false;
            try {
                if (!TryGetCreationTimeFromHandle(h, out long liveTime) || liveTime != expectedCreationTime) {
                    return false;
                }
                return TerminateProcess(h, 1);
            } finally {
                CloseHandle(h);
            }
        }

        private static List<DescendantInfo> GetDescendantsOrdered(int rootPid) {
            var children = new Dictionary<int, List<KeyValuePair<int, string>>>();
            IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) {
                return new List<DescendantInfo>();
            }
            try {
                var pe = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf<PROCESSENTRY32>() };
                if (Process32FirstW(snap, ref pe)) {
                    do {
                        int parent = (int)pe.th32ParentProcessID;
                        int pid = (int)pe.th32ProcessID;
                        if (pid == parent) continue;
                        if (!children.TryGetValue(parent, out var list)) {
                            list = new List<KeyValuePair<int, string>>();
                            children[parent] = list;
                        }
                        list.Add(new KeyValuePair<int, string>(pid, pe.szExeFile ?? string.Empty));
                    } while (Process32NextW(snap, ref pe));
                }
            } finally {
                CloseHandle(snap);
            }

            var result = new List<DescendantInfo>();
            var queue = new Queue<int>();
            var seen = new HashSet<int> { rootPid };
            var times = new Dictionary<int, long>();
            times[rootPid] = GetProcessCreationTime(rootPid);
            queue.Enqueue(rootPid);

            while (queue.Count > 0) {
                int cur = queue.Dequeue();
                long parentTime = times.TryGetValue(cur, out long pt) ? pt : 0;
                if (!children.TryGetValue(cur, out var list)) continue;
                foreach (var kv in list) {
                    if (!seen.Add(kv.Key)) continue;
                    long childTime = GetProcessCreationTime(kv.Key);
                    if (parentTime > 0 && childTime > 0 && childTime < parentTime) {
                        continue;
                    }
                    times[kv.Key] = childTime;
                    string name = kv.Value;
                    if (!name.Equals("conhost.exe", StringComparison.OrdinalIgnoreCase) &&
                        !name.Equals("OpenConsole.exe", StringComparison.OrdinalIgnoreCase)) {
                        result.Add(new DescendantInfo { Pid = kv.Key, Name = name, CreationTime = childTime });
                    }
                    queue.Enqueue(kv.Key);
                }
            }
            return result;
        }

        private static Dictionary<int, KeyValuePair<string, long>> GetDescendantsSnapshot(int rootPid) {
            var ordered = GetDescendantsOrdered(rootPid);
            var result = new Dictionary<int, KeyValuePair<string, long>>(ordered.Count);
            foreach (var info in ordered) {
                result[info.Pid] = new KeyValuePair<string, long>(info.Name, info.CreationTime);
            }
            return result;
        }

        public static Dictionary<int, string> GetDescendantsMap(int rootPid) {
            var snap = GetDescendantsSnapshot(rootPid);
            var map = new Dictionary<int, string>(snap.Count);
            foreach (var kv in snap) {
                map[kv.Key] = kv.Value.Key;
            }
            return map;
        }

        public static Dictionary<int, long> CaptureBaseline(int rootPid) {
            var snap = GetDescendantsSnapshot(rootPid);
            var baseline = new Dictionary<int, long>(snap.Count);
            foreach (var kv in snap) {
                baseline[kv.Key] = kv.Value.Value;
            }
            return baseline;
        }

        private static bool IsSameBaselineProcess(int pid, long currentTime, Dictionary<int, long> baseline) {
            if (baseline == null || !baseline.TryGetValue(pid, out long baseTime)) return false;
            if (baseTime > 0 && currentTime > 0 && currentTime != baseTime) return false;
            return true;
        }

        public static string[] GetNewChildren(int rootPid, Dictionary<int, long> baseline) {
            var cur = GetDescendantsSnapshot(rootPid);
            var rem = new List<string>();
            foreach (var kv in cur) {
                if (!IsSameBaselineProcess(kv.Key, kv.Value.Value, baseline)) {
                    rem.Add(kv.Value.Key + "#" + kv.Key);
                }
            }
            rem.Sort(StringComparer.OrdinalIgnoreCase);
            return rem.ToArray();
        }

        public static string[] GetNewChildren(int rootPid, HashSet<int> baseline) {
            var dict = new Dictionary<int, long>();
            if (baseline != null) {
                foreach (int pid in baseline) dict[pid] = 0;
            }
            return GetNewChildren(rootPid, dict);
        }

        public static string[] KillNewChildren(int rootPid, Dictionary<int, long> baseline) {
            var killed = new List<string>();
            var killedPids = new HashSet<int>();
            for (int pass = 0; pass < 3; pass++) {
                var cur = GetDescendantsOrdered(rootPid);
                bool anyKilledInPass = false;
                for (int i = cur.Count - 1; i >= 0; i--) {
                    var info = cur[i];
                    if (info.CreationTime <= 0) continue;
                    if (IsSameBaselineProcess(info.Pid, info.CreationTime, baseline)) continue;
                    if (killedPids.Contains(info.Pid)) continue;
                    if (TryKillVerified(info.Pid, info.CreationTime)) {
                        killedPids.Add(info.Pid);
                        killed.Add(info.Name + "#" + info.Pid);
                        anyKilledInPass = true;
                    }
                }
                if (!anyKilledInPass) break;
            }
            killed.Sort(StringComparer.OrdinalIgnoreCase);
            return killed.ToArray();
        }

        public static string[] KillNewChildren(int rootPid, HashSet<int> baseline) {
            var dict = new Dictionary<int, long>();
            if (baseline != null) {
                foreach (int pid in baseline) dict[pid] = 0;
            }
            return KillNewChildren(rootPid, dict);
        }
    }
}
"@
    try {
        Add-Type -TypeDefinition $src -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-AgentToolsDescendantMap {
    # Retorna mapa PID -> nome de processos descendentes do PID informado.
    param([int]$RootPid = $PID)
    if (-not (Initialize-AgentToolsProcessTree)) { return , @{} }
    $pt = Get-AgentToolsProcessTreeType
    return , ($pt::GetDescendantsMap($RootPid))
}

function Get-AgentToolsProcessBaseline {
    # Captura baseline PID -> CreationTime (FILETIME) dos descendentes atuais do PID informado.
    param([int]$RootPid = $PID)
    if (-not (Initialize-AgentToolsProcessTree)) { return $null }
    $pt = Get-AgentToolsProcessTreeType
    return , ($pt::CaptureBaseline($RootPid))
}

function Get-AgentToolsNewChild {
    # Retorna lista ordenada 'nome#pid' de descendentes criados após o baseline (validando tempo de criação).
    param([int]$RootPid = $PID, $Baseline)
    if (-not (Initialize-AgentToolsProcessTree)) { return [string[]]@() }
    $pt = Get-AgentToolsProcessTreeType
    return [string[]]@($pt::GetNewChildren($RootPid, $Baseline))
}

function Stop-AgentToolsNewChild {
    # Encerra processos descendentes criados após o baseline (validando tempo de criação) e retorna 'nome#pid'.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Auxiliar privado de limpeza de processos filhos em timeout ou interrupção.')]
    param([int]$RootPid = $PID, $Baseline)
    if (-not (Initialize-AgentToolsProcessTree)) { return [string[]]@() }
    $pt = Get-AgentToolsProcessTreeType
    return [string[]]@($pt::KillNewChildren($RootPid, $Baseline))
}
