function Get-IcpStatusBarType {
    # Retorna o tipo .NET versionado IcpStatusBar carregado para a versão atual do módulo.
    $ns = if ($script:AgentToolsTypeNamespace) { $script:AgentToolsTypeNamespace } else { 'AgentTools.V1_1_0' }
    return ("$ns.IcpStatusBar" -as [type])
}

function Initialize-IcpStatusBar {
    # Compila helper C# versionado para barra de status DEC 2026, ligado via delegates ao ProcessTree.
    if (-not (Initialize-AgentToolsProcessTree)) { return $false }
    $ns = if ($script:AgentToolsTypeNamespace) { $script:AgentToolsTypeNamespace } else { 'AgentTools.V1_1_0' }
    if ($null -eq (Get-IcpStatusBarType)) {
        $src = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace $ns {
    public sealed class IcpStatusBar : IDisposable {
        public static Func<int, Dictionary<int, string>> DescendantsProvider;
        public static Func<int, Dictionary<int, long>> CaptureBaselineProvider;
        public static Func<int, Dictionary<int, long>, string[]> NewChildrenProvider;
        public static Func<int, Dictionary<int, long>, string[]> KillNewChildrenProvider;

        public static Dictionary<int, string> GetDescendantsMap(int rootPid) {
            return DescendantsProvider != null ? DescendantsProvider(rootPid) : new Dictionary<int, string>();
        }

        public static Dictionary<int, long> CaptureBaseline(int rootPid) {
            return CaptureBaselineProvider != null ? CaptureBaselineProvider(rootPid) : new Dictionary<int, long>();
        }

        public static string[] GetNewChildren(int rootPid, Dictionary<int, long> baseline) {
            return NewChildrenProvider != null ? NewChildrenProvider(rootPid, baseline) : Array.Empty<string>();
        }

        public static string[] GetNewChildren(int rootPid, HashSet<int> baseline) {
            var dict = new Dictionary<int, long>();
            if (baseline != null) {
                foreach (int pid in baseline) dict[pid] = 0;
            }
            return GetNewChildren(rootPid, dict);
        }

        private static string[] KillNewChildren(int rootPid, Dictionary<int, long> baseline) {
            return KillNewChildrenProvider != null ? KillNewChildrenProvider(rootPid, baseline) : Array.Empty<string>();
        }

        private static readonly string[] Frames = new[] { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

        private const string AnsiPetroleo      = "\u001b[38;2;69;133;136m";
        private const string AnsiPetroleoClaro = "\u001b[38;2;131;165;152m";
        private const string AnsiPedra         = "\u001b[38;2;102;92;84m";
        private const string AnsiCreme         = "\u001b[38;2;251;241;199m";
        private const string AnsiAmbar         = "\u001b[38;2;250;189;47m";
        private const string AnsiLaranja       = "\u001b[38;2;254;128;25m";
        private const string AnsiTerracota     = "\u001b[91m";
        private const string AnsiReset         = "\u001b[0m";

        private static string FormatDuration(double sec) {
            if (sec < 0) sec = 0;
            if (sec < 60.0) return sec.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "s";
            int mins = (int)(sec / 60.0);
            int rem = (int)(sec % 60.0);
            return mins.ToString() + "m" + rem.ToString("00") + "s";
        }

        public static string BuildBar(int index, int total) {
            if (total <= 0) return string.Empty;
            if (index > total) return "━━━━━";
            if (total == 1) return "━━╺──";
            int width = 5;
            int curIdx = Math.Min(width - 1, (int)Math.Floor((double)Math.Max(0, index - 1) * width / total));
            var sb = new StringBuilder(width);
            for (int i = 0; i < width; i++) {
                if (i < curIdx) sb.Append('━');
                else if (i == curIdx) sb.Append('╺');
                else sb.Append('─');
            }
            return sb.ToString();
        }

        private static List<KeyValuePair<string, string>> BuildExtraParts(
            string origin, string label, double idleSec,
            int outputCount, int errorCount, int silentErrorCount, int stderrCount,
            string[] activeChildren, bool timedOut, int timeoutSec,
            string cPetroleoClaro, string cCreme, string cLaranja, string cErro) {
            var extras = new List<KeyValuePair<string, string>>();
            if (timedOut) {
                string toMsg = "⚠ TIMEOUT (" + timeoutSec + "s)";
                if (activeChildren == null || activeChildren.Length == 0) {
                    toMsg += " · laço PS · Ctrl+C";
                }
                extras.Add(new KeyValuePair<string, string>(toMsg, cErro));
            } else if (errorCount > 0) {
                extras.Add(new KeyValuePair<string, string>("⚠ " + errorCount + " erro(s)", cErro));
            } else if (idleSec >= 8.0) {
                extras.Add(new KeyValuePair<string, string>("⚠ sem saída há " + ((int)idleSec) + "s", cLaranja));
            }

            if (silentErrorCount > 0) {
                extras.Add(new KeyValuePair<string, string>("silencioso: " + silentErrorCount, cLaranja));
            }
            if (stderrCount > 0 && errorCount == 0) {
                extras.Add(new KeyValuePair<string, string>("stderr: " + stderrCount, cLaranja));
            }
            if (!string.IsNullOrEmpty(origin)) {
                extras.Add(new KeyValuePair<string, string>(origin, cPetroleoClaro));
            }
            if (activeChildren != null && activeChildren.Length > 0) {
                string childText = activeChildren.Length == 1
                    ? "filho: " + activeChildren[0]
                    : "filhos(" + activeChildren.Length + "): " + activeChildren[0] + ", " + activeChildren[1];
                extras.Add(new KeyValuePair<string, string>(childText, cPetroleoClaro));
            }
            if (outputCount > 0 && idleSec < 8.0) {
                extras.Add(new KeyValuePair<string, string>(outputCount + " linhas", cPetroleoClaro));
            }
            if (idleSec >= 8.0 && !timedOut) {
                extras.Add(new KeyValuePair<string, string>("Ctrl+C p/ parar", cLaranja));
            }
            if (!string.IsNullOrEmpty(label)) {
                extras.Add(new KeyValuePair<string, string>(label, cCreme));
            }
            return extras;
        }

        public static string FormatPlainLine(
            int index, int total, string origin, string label,
            double elapsedSec, double idleSec,
            int outputCount, int errorCount, int silentErrorCount, int stderrCount,
            string[] activeChildren, bool timedOut, int timeoutSec, int maxWidth) {
            var parts = new List<string>();
            string bar = BuildBar(index, total);
            string head = string.IsNullOrEmpty(bar)
                ? "[" + index + "/" + total + "] " + FormatDuration(elapsedSec)
                : bar + " [" + index + "/" + total + "] " + FormatDuration(elapsedSec);
            parts.Add(head);

            foreach (var seg in BuildExtraParts(origin, label, idleSec, outputCount, errorCount,
                silentErrorCount, stderrCount, activeChildren, timedOut, timeoutSec,
                AnsiPetroleoClaro, AnsiCreme, AnsiLaranja, AnsiTerracota)) {
                parts.Add(seg.Key);
            }

            string full = string.Join(" · ", parts);
            int limit = Math.Max(16, maxWidth - 4);
            if (full.Length > limit) {
                full = full.Substring(0, limit - 1) + "…";
            }
            return full;
        }

        public static string RenderLine(
            int frameIndex, int index, int total, string origin, string label,
            double elapsedSec, double idleSec,
            int outputCount, int errorCount, int silentErrorCount, int stderrCount,
            string[] activeChildren, bool timedOut, int timeoutSec, int maxWidth,
            bool noColor, string linePrefix = "") {
            return RenderLine(frameIndex, index, total, origin, label, elapsedSec, idleSec,
                outputCount, errorCount, silentErrorCount, stderrCount, activeChildren,
                timedOut, timeoutSec, maxWidth, noColor, linePrefix, null);
        }

        public static string RenderLine(
            int frameIndex, int index, int total, string origin, string label,
            double elapsedSec, double idleSec,
            int outputCount, int errorCount, int silentErrorCount, int stderrCount,
            string[] activeChildren, bool timedOut, int timeoutSec, int maxWidth,
            bool noColor, string linePrefix, string[] palette) {
            string prefix = linePrefix ?? string.Empty;
            int idx = frameIndex < 0 ? 0 : frameIndex;
            string frameChar = Frames[idx % Frames.Length];
            int mode = (timedOut || errorCount > 0) ? 2 : ((idleSec >= 8.0 || silentErrorCount > 0 || stderrCount > 0) ? 1 : 0);

            if (noColor) {
                int avail = Math.Max(20, maxWidth - prefix.Length - 2);
                return prefix + frameChar + " " + FormatPlainLine(index, total, origin, label, elapsedSec, idleSec,
                    outputCount, errorCount, silentErrorCount, stderrCount, activeChildren, timedOut, timeoutSec, avail);
            }

            bool hasPal = palette != null && palette.Length >= 7;
            string cPetroleo      = (hasPal && palette[0] != null) ? palette[0] : AnsiPetroleo;
            string cPetroleoClaro = (hasPal && palette[1] != null) ? palette[1] : AnsiPetroleoClaro;
            string cPedra         = (hasPal && palette[2] != null) ? palette[2] : AnsiPedra;
            string cCreme         = (hasPal && palette[3] != null) ? palette[3] : AnsiCreme;
            string cAmbar         = (hasPal && palette[4] != null) ? palette[4] : AnsiAmbar;
            string cLaranja       = (hasPal && palette[5] != null) ? palette[5] : AnsiLaranja;
            string cErro          = (hasPal && palette[6] != null) ? palette[6] : AnsiTerracota;

            string accent = mode == 2 ? cErro : (mode == 1 ? cLaranja : cPetroleoClaro);
            string doneColor = mode == 2 ? cErro : (mode == 1 ? cLaranja : cPetroleo);
            string curColor = mode == 2 ? cErro : (mode == 1 ? cLaranja : cAmbar);
            string durColor = mode == 2 ? cErro : (mode == 1 ? cLaranja : cAmbar);

            var tokens = new List<KeyValuePair<string, string>>();
            string bar = BuildBar(index, total);
            if (!string.IsNullOrEmpty(bar)) {
                int splitCur = bar.IndexOf('╺');
                if (splitCur < 0) {
                    tokens.Add(new KeyValuePair<string, string>(bar, doneColor));
                } else {
                    if (splitCur > 0) tokens.Add(new KeyValuePair<string, string>(bar.Substring(0, splitCur), doneColor));
                    tokens.Add(new KeyValuePair<string, string>("╺", curColor));
                    if (splitCur + 1 < bar.Length) tokens.Add(new KeyValuePair<string, string>(bar.Substring(splitCur + 1), cPedra));
                }
                tokens.Add(new KeyValuePair<string, string>(" ", null));
            }
            tokens.Add(new KeyValuePair<string, string>("[" + index + "/" + total + "]", cCreme));
            tokens.Add(new KeyValuePair<string, string>(" " + FormatDuration(elapsedSec), durColor));

            foreach (var seg in BuildExtraParts(origin, label, idleSec, outputCount, errorCount,
                silentErrorCount, stderrCount, activeChildren, timedOut, timeoutSec,
                cPetroleoClaro, cCreme, cLaranja, cErro)) {
                tokens.Add(new KeyValuePair<string, string>(" · ", cPedra));
                tokens.Add(seg);
            }

            int limit = Math.Max(16, maxWidth - prefix.Length - 2 - 4);
            var sb = new StringBuilder(256);
            string activeColor = string.Empty;
            if (!string.IsNullOrEmpty(prefix)) {
                if (!string.IsNullOrEmpty(cPedra)) {
                    sb.Append(cPedra);
                    activeColor = cPedra;
                }
                sb.Append(prefix);
            }
            if (!string.IsNullOrEmpty(accent) && activeColor != accent) {
                sb.Append(accent);
                activeColor = accent;
            }
            sb.Append(frameChar).Append(' ');

            int used = 0;
            foreach (var tok in tokens) {
                if (string.IsNullOrEmpty(tok.Key)) continue;
                int remaining = limit - used;
                if (remaining <= 0) break;
                if (tok.Value != null && activeColor != tok.Value) {
                    if (tok.Value.Length == 0) {
                        if (!string.IsNullOrEmpty(activeColor)) {
                            sb.Append(AnsiReset);
                            activeColor = string.Empty;
                        }
                    } else {
                        sb.Append(tok.Value);
                        activeColor = tok.Value;
                    }
                }
                if (used + tok.Key.Length <= limit) {
                    sb.Append(tok.Key);
                    used += tok.Key.Length;
                } else {
                    int take = Math.Max(0, remaining - 1);
                    if (take > 0) sb.Append(tok.Key.Substring(0, take));
                    sb.Append('…');
                    break;
                }
            }
            if (!string.IsNullOrEmpty(activeColor)) {
                sb.Append(AnsiReset);
            }
            return sb.ToString();
        }

        public static string BuildFrame(
            int frameIndex, int index, int total, string origin, string label,
            double elapsedSec, double idleSec,
            int outputCount, int errorCount, int silentErrorCount, int stderrCount,
            string[] activeChildren, bool timedOut, int timeoutSec, int maxWidth,
            bool noColor, bool hideCursor, string linePrefix = "") {
            return BuildFrame(frameIndex, index, total, origin, label, elapsedSec, idleSec,
                outputCount, errorCount, silentErrorCount, stderrCount, activeChildren,
                timedOut, timeoutSec, maxWidth, noColor, hideCursor, linePrefix, null);
        }

        public static string BuildFrame(
            int frameIndex, int index, int total, string origin, string label,
            double elapsedSec, double idleSec,
            int outputCount, int errorCount, int silentErrorCount, int stderrCount,
            string[] activeChildren, bool timedOut, int timeoutSec, int maxWidth,
            bool noColor, bool hideCursor, string linePrefix, string[] palette) {
            string line = RenderLine(frameIndex, index, total, origin, label, elapsedSec, idleSec,
                outputCount, errorCount, silentErrorCount, stderrCount, activeChildren,
                timedOut, timeoutSec, maxWidth, noColor, linePrefix, palette);
            return "\u001b[?2026h\r" + (hideCursor ? "\u001b[?25l" : string.Empty) + line + "\u001b[K\u001b[?2026l";
        }

        public static string BuildClearSequence(bool restoreCursor) {
            return "\u001b[?2026h\r\u001b[K" + (restoreCursor ? "\u001b[?25h" : string.Empty) + "\u001b[?2026l";
        }

        public static string BuildClearSequence() {
            return BuildClearSequence(true);
        }

        private readonly object _lock = new object();
        private readonly bool _renderEnabled;
        private readonly bool _framed;
        private readonly string[] _palette;
        private readonly bool _noColor;
        private readonly int _rootPid;
        private Timer _timer;
        private Dictionary<int, long> _baselinePids = new Dictionary<int, long>();
        private Stopwatch _cmdSw = new Stopwatch();
        private Stopwatch _lastOutputSw = new Stopwatch();
        private int _index;
        private int _total;
        private string _origin = string.Empty;
        private string _label = string.Empty;
        private int _timeoutMs;
        private int _timeoutSec;
        private int _outputCount;
        private int _errorCount;
        private int _silentErrorCount;
        private int _stderrCount;
        private int _frame;
        private long _lastChildCheckMs;
        private string[] _activeChildren = Array.Empty<string>();
        private string[] _lastActiveChildrenWithPid = Array.Empty<string>();
        private double _lastIdleSec = 0.0;
        private bool _active;
        private bool _drawn;
        private bool _cursorWasVisible = true;
        private bool _cursorHiddenByBar;
        private bool _needsChildTracking;

        public volatile bool TimedOut;
        public bool IsDisposed { get; private set; }
        public string KilledSummary { get; private set; } = string.Empty;
        public string[] RemainingChildren { get; private set; } = Array.Empty<string>();
        public string[] LastActiveChildren { get { lock (_lock) { return (string[])_lastActiveChildrenWithPid.Clone(); } } }
        public double LastIdleSeconds { get { lock (_lock) { return _active ? (_lastOutputSw.ElapsedMilliseconds / 1000.0) : _lastIdleSec; } } }
        public int ErrorCount { get { lock (_lock) { return _errorCount; } } }
        public int SilentErrorCount { get { lock (_lock) { return _silentErrorCount; } } }

        public IcpStatusBar(bool renderEnabled) : this(renderEnabled, false, null) { }

        public IcpStatusBar(bool renderEnabled, bool framed) : this(renderEnabled, framed, null) { }

        public IcpStatusBar(bool renderEnabled, bool framed, string[] palette) {
            _renderEnabled = renderEnabled;
            _framed = framed;
            _palette = palette;
            _noColor = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NO_COLOR"));
            _rootPid = Environment.ProcessId;
        }

        public void BeginCommand(int index, int total, string origin, string label, int timeoutSeconds) {
            lock (_lock) {
                if (IsDisposed) return;
                _index = index;
                _total = total;
                _origin = origin ?? string.Empty;
                _label = label ?? string.Empty;
                _timeoutSec = timeoutSeconds;
                _timeoutMs = timeoutSeconds > 0 ? timeoutSeconds * 1000 : 0;
                _needsChildTracking = _renderEnabled || _timeoutMs > 0;
                _baselinePids = _needsChildTracking
                    ? CaptureBaseline(_rootPid)
                    : new Dictionary<int, long>();
                _outputCount = 0;
                _errorCount = 0;
                _silentErrorCount = 0;
                _stderrCount = 0;
                _frame = 0;
                _lastChildCheckMs = -650;
                _activeChildren = Array.Empty<string>();
                _lastActiveChildrenWithPid = Array.Empty<string>();
                _lastIdleSec = 0.0;
                _drawn = false;
                _cursorWasVisible = true;
                _cursorHiddenByBar = false;
                TimedOut = false;
                KilledSummary = string.Empty;
                RemainingChildren = Array.Empty<string>();
                _cmdSw.Restart();
                _lastOutputSw.Restart();
                _active = true;
                int dueMs = _renderEnabled ? 140 : 200;
                int periodMs = _renderEnabled ? 90 : 200;
                if (_timer == null) {
                    _timer = new Timer(Tick, null, dueMs, periodMs);
                } else {
                    _timer.Change(dueMs, periodMs);
                }
            }
        }

        public void NoteOutput() {
            lock (_lock) { _outputCount++; _lastOutputSw.Restart(); }
        }
        public void NoteError() {
            lock (_lock) { _errorCount++; _lastOutputSw.Restart(); }
        }
        public void NoteStderr() {
            lock (_lock) { _stderrCount++; _lastOutputSw.Restart(); }
        }
        public void NoteSilentError(int totalSilent) {
            lock (_lock) { if (totalSilent > _silentErrorCount) _silentErrorCount = totalSilent; }
        }

        private void Tick(object state) {
            if (!Monitor.TryEnter(_lock)) return;
            try {
                if (!_active || IsDisposed) return;
                long elapsedMs = _cmdSw.ElapsedMilliseconds;
                if (_needsChildTracking && (elapsedMs - _lastChildCheckMs >= 900 || (_timeoutMs > 0 && elapsedMs >= _timeoutMs))) {
                    _lastChildCheckMs = elapsedMs;
                    var rawNew = GetNewChildren(_rootPid, _baselinePids);
                    if (rawNew.Length > 0) {
                        _lastActiveChildrenWithPid = rawNew;
                    }
                    var activeList = new List<string>(rawNew.Length);
                    foreach (var item in rawNew) {
                        int hashIdx = item.LastIndexOf('#');
                        activeList.Add(hashIdx > 0 ? item.Substring(0, hashIdx) : item);
                    }
                    _activeChildren = activeList.ToArray();

                    if (_timeoutMs > 0 && !TimedOut && elapsedMs >= _timeoutMs) {
                        TimedOut = true;
                        var killed = KillNewChildren(_rootPid, _baselinePids);
                        KilledSummary = string.Join(", ", killed);
                    }
                }

                if (_renderEnabled) {
                    int w = 120;
                    try { w = Console.WindowWidth; } catch { w = 120; }
                    if (w < 40) w = 40;
                    double elapsedSec = elapsedMs / 1000.0;
                    double idleSec = _lastOutputSw.ElapsedMilliseconds / 1000.0;
                    string prefix = _framed ? "│ " : string.Empty;
                    bool hideCursor = false;
                    if (!_drawn) {
                        bool wasVisible = true;
                        try { wasVisible = Console.CursorVisible; } catch { wasVisible = true; }
                        _cursorWasVisible = wasVisible;
                        hideCursor = wasVisible;
                    }
                    string frame = BuildFrame(_frame, _index, _total, _origin, _label, elapsedSec, idleSec,
                        _outputCount, _errorCount, _silentErrorCount, _stderrCount,
                        _activeChildren, TimedOut, _timeoutSec, w, _noColor, hideCursor, prefix, _palette);
                    try {
                        Console.Write(frame);
                        _drawn = true;
                        if (hideCursor) _cursorHiddenByBar = true;
                    } catch { }
                    _frame++;
                }
            } finally {
                Monitor.Exit(_lock);
            }
        }

        public string[] KillActiveChildren() {
            Dictionary<int, long> baseline;
            int rootPid;
            lock (_lock) {
                if (!_needsChildTracking) return Array.Empty<string>();
                baseline = _baselinePids;
                rootPid = _rootPid;
            }
            return KillNewChildren(rootPid, baseline);
        }

        public void EndCommand() {
            lock (_lock) {
                if (!_active) return;
                _active = false;
                if (_timer != null) _timer.Change(Timeout.Infinite, Timeout.Infinite);
                if (_drawn) {
                    try { Console.Write(BuildClearSequence(_cursorHiddenByBar && _cursorWasVisible)); } catch { }
                    _drawn = false;
                    _cursorHiddenByBar = false;
                }
                if (_needsChildTracking) {
                    RemainingChildren = GetNewChildren(_rootPid, _baselinePids);
                    if (RemainingChildren.Length > 0) {
                        _lastActiveChildrenWithPid = RemainingChildren;
                    }
                }
                _lastIdleSec = _lastOutputSw.ElapsedMilliseconds / 1000.0;
            }
        }

        public void Dispose() {
            EndCommand();
            Timer t = null;
            lock (_lock) {
                if (IsDisposed) return;
                IsDisposed = true;
                _active = false;
                t = _timer;
                _timer = null;
            }
            if (t != null) {
                try {
                    using (var wh = new ManualResetEvent(false)) {
                        if (t.Dispose(wh)) {
                            wh.WaitOne(250);
                        }
                    }
                } catch { }
            }
        }
    }
}
"@
        try {
            Add-Type -TypeDefinition $src -ErrorAction Stop
        }
        catch {
            return $false
        }
    }
    try {
        $ptType = Get-AgentToolsProcessTreeType
        $sbType = Get-IcpStatusBarType
        if ($null -eq $ptType -or $null -eq $sbType) { return $false }
        $dictLong = [System.Collections.Generic.Dictionary[int, long]]
        if ($null -eq $sbType::DescendantsProvider) {
            $sbType::DescendantsProvider = [Delegate]::CreateDelegate(
                [Func[int, System.Collections.Generic.Dictionary[int, string]]],
                $ptType.GetMethod('GetDescendantsMap', [type[]]@([int]))
            )
        }
        if ($null -eq $sbType::CaptureBaselineProvider) {
            $sbType::CaptureBaselineProvider = [Delegate]::CreateDelegate(
                [Func[int, System.Collections.Generic.Dictionary[int, long]]],
                $ptType.GetMethod('CaptureBaseline', [type[]]@([int]))
            )
        }
        if ($null -eq $sbType::NewChildrenProvider) {
            $sbType::NewChildrenProvider = [Delegate]::CreateDelegate(
                [Func[int, System.Collections.Generic.Dictionary[int, long], string[]]],
                $ptType.GetMethod('GetNewChildren', [type[]]@([int], $dictLong))
            )
        }
        if ($null -eq $sbType::KillNewChildrenProvider) {
            $sbType::KillNewChildrenProvider = [Delegate]::CreateDelegate(
                [Func[int, System.Collections.Generic.Dictionary[int, long], string[]]],
                $ptType.GetMethod('KillNewChildren', [type[]]@([int], $dictLong))
            )
        }
        return $true
    }
    catch {
        return $false
    }
}

function Measure-IcpLinhasBloco {
    # Calcula quantas linhas visuais o bloco invocado ocupou na tela e se cabe para recolher.
    param(
        [string]$InvocationLine,
        [string]$ScriptBlockText,
        [int]$WindowWidth = 120,
        [int]$WindowHeight = 30,
        [int]$PromptWidth = 0
    )
    $w = if ($WindowWidth -lt 20) { 20 } else { $WindowWidth }
    $sbTexto = if ($null -eq $ScriptBlockText) { '' } else { $ScriptBlockText }
    $sbLinhas = @($sbTexto -split '\r?\n')
    $invTexto = if ($null -eq $InvocationLine) { '' } else { $InvocationLine.TrimEnd() }
    $visuais = [System.Collections.Generic.List[string]]::new()
    if ($sbLinhas.Count -le 1) {
        $primeira = if ($invTexto) { $invTexto } else { $sbTexto.TrimEnd() }
        if ($primeira) { $visuais.Add($primeira) }
    }
    else {
        $primeira = if ($invTexto) { $invTexto } else { $sbLinhas[0] }
        $visuais.Add($primeira)
        for ($i = 1; $i -lt $sbLinhas.Count; $i++) {
            $visuais.Add($sbLinhas[$i])
        }
    }
    $total = 0
    for ($i = 0; $i -lt $visuais.Count; $i++) {
        $extra = if ($i -eq 0 -and $PromptWidth -gt 0) { $PromptWidth } else { 0 }
        $len = $extra + $visuais[$i].Length
        $total += [Math]::Max(1, [int][Math]::Ceiling($len / [double]$w))
    }
    $cabe = ($total -gt 0) -and ($WindowHeight -ge 4) -and ($total -lt ($WindowHeight - 2))
    return [pscustomobject]@{
        Linhas   = $total
        Cabe     = $cabe
        Recolher = if ($cabe) { $total } else { 0 }
    }
}

function Show-IcpDemo {
    # Simulação visual (~4s) dos estados da barra sem rodar comandos reais e sem tocar o clipboard.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Exibe simulação visual no terminal sem alterar área de transferência.')]
    param()
    $temBar = Initialize-IcpStatusBar
    $barType = if ($temBar) { Get-IcpStatusBarType } else { $null }
    $interativo = Test-IcpInterativo
    if (-not $interativo) {
        Write-Host 'AgentTools icp -Demo (modo não interativo: saída estática)'
        if ($null -ne $barType) {
            $n1 = $barType::FormatPlainLine(1, 3, 'nativo: git.exe', 'git status --short', 1.4, 0.2, 4, 0, 0, 0, @(), $false, 0, 100)
            $n2 = $barType::FormatPlainLine(2, 3, 'nativo: pwsh.exe', 'Invoke-Build -Target Test', 9.2, 9.2, 0, 0, 1, 0, @('pwsh.exe'), $false, 0, 100)
            Write-Host "[Normal] $n1"
            Write-Host "[Alerta 8s] $n2"
        }
        else {
            Write-Host '[Normal] ╺──── [1/3] 1.4s · nativo: git.exe · git status --short'
            Write-Host '[Alerta 8s] ━╺─── [2/3] 9.2s · ⚠ sem saída há 9s · silencioso: 1 · Invoke-Build'
        }
        Write-Host '[Conclusão] ╰─ ✓ Resultado: OK (10.6s · compacto)'
        return
    }

    $noColor = -not [string]::IsNullOrEmpty($env:NO_COLOR)
    $pal = Get-IcpStatusBarPalette
    $w = try { [Console]::WindowWidth } catch { 120 }
    if ($w -lt 40) { $w = 120 }
    Write-Host ''
    Write-Host "$(Format-IcpCor '╭─' 'Petroleo') $(Format-IcpCor 'icp' 'Ambar' -Negrito) $(Format-IcpCor '· demonstração animada (sem comandos reais · sem clipboard)' 'Neutro')"
    Write-Host "$(Format-IcpCor '│ ' 'Pedra')$(Format-IcpCor '[1/3]' 'Neutro') $(Format-IcpCor '✓ OK' 'Oliva' -Negrito) $(Format-IcpComandoColorido -Texto 'git status --short') $(Format-IcpCor '(142 ms)' 'Pedra')"

    try {
        $frame = 0
        for ($i = 0; $i -lt 15; $i++) {
            $sec = 0.2 + ($i * 0.09)
            $seq = $barType::BuildFrame($frame, 2, 3, 'nativo: dotnet.exe', 'dotnet build --no-restore',
                $sec, 0.2, 6, 0, 0, 0, @(), $false, 0, $w, $noColor, ($frame -eq 0), '│ ', $pal)
            [Console]::Write($seq)
            $frame++
            Start-Sleep -Milliseconds 90
        }
        for ($i = 0; $i -lt 17; $i++) {
            $sec = 8.2 + ($i * 0.1)
            $seq = $barType::BuildFrame($frame, 2, 3, 'nativo: dotnet.exe', 'dotnet test --no-build',
                $sec, $sec, 0, 0, 1, 0, @('dotnet.exe'), $false, 0, $w, $noColor, $false, '│ ', $pal)
            [Console]::Write($seq)
            $frame++
            Start-Sleep -Milliseconds 90
        }
        [Console]::Write($barType::BuildClearSequence())
        Write-Host "$(Format-IcpCor '│ ' 'Pedra')$(Format-IcpCor '[2/3]' 'Neutro') $(Format-IcpCor '✓ OK' 'Oliva' -Negrito) $(Format-IcpComandoColorido -Texto 'dotnet test --no-build') $(Format-IcpCor '(9.9s)' 'Pedra')"
        Write-Host "$(Format-IcpCor '│ ' 'Pedra')  $(Format-IcpCor '[SILENCIOSO] +1 erro(s) silencioso(s) registrado(s) em $global:Error' 'Laranja')"

        for ($i = 0; $i -lt 11; $i++) {
            $sec = 0.1 + ($i * 0.09)
            $seq = $barType::BuildFrame($frame, 3, 3, 'interno: Invoke-Pester', 'Invoke-Pester -Path Tests',
                $sec, 0.1, 12, 0, 0, 0, @(), $false, 0, $w, $noColor, $true, '│ ', $pal)
            [Console]::Write($seq)
            $frame++
            Start-Sleep -Milliseconds 90
        }
        [Console]::Write($barType::BuildClearSequence())
        Write-Host "$(Format-IcpCor '│ ' 'Pedra')$(Format-IcpCor '[3/3]' 'Neutro') $(Format-IcpCor '✓ OK' 'Oliva' -Negrito) $(Format-IcpComandoColorido -Texto 'Invoke-Pester -Path Tests') $(Format-IcpCor '(1.0s)' 'Pedra')"
    }
    finally {
        if ($null -ne $barType) {
            try { [Console]::Write($barType::BuildClearSequence()) } catch { $null = $_ }
        }
        else {
            try { [Console]::Write("`e[?25h") } catch { $null = $_ }
        }
    }
    Write-Host "$(Format-IcpCor '╰─' 'Petroleo') $(Format-IcpCor '✓ Resultado: OK' 'Oliva' -Negrito) $(Format-IcpCor '(11.0s · demonstração · clipboard intacto)' 'Neutro')"
    Write-Host ''
}
