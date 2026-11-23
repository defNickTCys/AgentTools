# Changelog

## 1.0.0

- Publica o AgentTools como módulo independente, com instalação documentada, metadados do projeto e licença MIT.
- Alinha as descrições de diagnóstico e as notas de exemplos em `icp -Help`, com cobertura de regressão.
- Atualiza a documentação e os exemplos do contrato de relatório v2.

## 0.9.5

- Separa o núcleo em `Core/` e a ferramenta em `Tools/icp/`, com carregamento sob demanda e motor isolado.
- Adota em definitivo o contrato de relatório v2, com XML compacto, JSON estrito e Markdown.
- Reforça o tratamento de aninhamento e interrupção. Registra códigos de saída aceitos e permite gravar relatórios diretamente em arquivo.

## 0.9.0

- Adiciona execução passo a passo com `-Step`, preserva cores nativas na tela e detalha a referência com `icp -Help -Full`.

## 0.8.0

- Introduz o compositor interativo, os temas de terminal e a barra de status com atualização sincronizada.
- Adiciona `-KeepBlock` e a demonstração visual com `icp -Help -Demo`.

## 0.1.0 a 0.7.x

- A primeira versão do `icp` executava blocos PowerShell em sequência e reunia a saída em um relatório.
- As versões seguintes acrescentaram ocultação de segredos, relatórios em arquivo para saídas grandes e leitura do fim de arquivos redirecionados.
- A série 0.7 refinou o pré-voo, os resumos de erro e os diagnósticos de erros silenciosos e processos filhos ativos.
