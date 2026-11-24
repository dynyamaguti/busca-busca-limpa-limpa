# Busca Busca Limpa Limpa

Libera espaço no SSD interno do Mac com um clique. Feito para editores.

<p align="center">
  <a href="https://github.com/dynyamaguti/busca-busca-limpa-limpa/releases/latest/download/BuscaBuscaLimpaLimpa.zip">
    <img src="https://img.shields.io/badge/Baixar%20para%20Mac-Download-2563eb?style=for-the-badge&logo=apple&logoColor=white" alt="Baixar para Mac" height="48">
  </a>
  <br><sub>macOS 13 ou mais novo · Apple Silicon e Intel</sub>
</p>

## Instalar

1. Clique em **Baixar para Mac** acima, abra o .zip e arraste o **Busca Busca Limpa Limpa** para a pasta **Aplicativos**.
2. Abra o app. O Mac vai avisar que não pode verificar o desenvolvedor (o app não é assinado pela Apple). Clique em **OK**.
3. Vá em **Ajustes do Sistema → Privacidade e Segurança**, role até o fim e clique em **Abrir Mesmo Assim** ao lado do nome do app.
   Se essa opção não aparecer, rode no Terminal e abra o app de novo:
   `xattr -dr com.apple.quarantine "/Applications/Busca Busca Limpa Limpa.app"`
4. Opcional, mas recomendado: em **Privacidade e Segurança → Acesso Total ao Disco**, clique no **+**, escolha o app em Aplicativos
   e deixe a chave ligada. Assim ele também vê as mídias do WhatsApp, esvazia a Lixeira e limpa o cache do Safari. Abra o app de novo depois.

Para atualizar: baixe de novo e substitua o app em Aplicativos. Se o rodapé mostrar "Sem Acesso Total ao Disco", refaça o passo 4.

## Usar

Abra o app. Ele analisa o Mac sozinho e mostra quanto dá para liberar. Clique em **Liberar X GB**.

- Se o Chrome, o DaVinci Resolve ou outro app estiver aberto, o Busca Busca Limpa Limpa pede para fechá-lo (salve o projeto antes)
  ou continua sem ele.
- Clique no nome de uma categoria para ver os itens. Dá para desmarcar um por um.
- Atalhos: ⌘R analisa de novo, ⌘⌫ libera o espaço marcado.

## O que é limpo

| Marcado por padrão (cache, o app recria sozinho) | Desmarcado (você escolhe) |
|---|---|
| Google Chrome, Safari, Brave, Edge, Arc, Firefox | Restos de apps desinstalados → vão para a Lixeira |
| DaVinci Resolve: CacheClip (render cache e mídia otimizada) e logs | Instaladores .dmg/.pkg em Downloads → vão para a Lixeira |
| Adobe: Media Cache, Peak Files, Disk Cache | Esvaziar Lixeira (apaga para sempre) |
| Slack, Discord, Spotify, VS Code, Claude e outros apps Electron | |
| Xcode DerivedData, simuladores, cache do npm | |
| Caches gerais (`~/Library/Caches`) e logs | **WhatsApp**: mídias de cada conversa no app do Mac e dados do WhatsApp Web (desconecta, precisa ler o QR code de novo). Precisa de Acesso Total ao Disco. |
| | **Modelos de IA**: Claude (máquina virtual ~10 GB), Gemini Nano do Chrome, pacotes de IA do Resolve, Hugging Face, Ollama, LM Studio. Nenhum vem marcado. |

Abra uma categoria (clique no nome ou no triângulo) para ver o que ela contém. Itens que pedem cuidado mostram um aviso em laranja, e o botão ⓘ explica em detalhes.
Os modelos da **Apple Intelligence** aparecem só como informação, porque o macOS protege esses arquivos.
O botão **Abrir Ajustes** leva direto à opção de desativar a Apple Intelligence, e aí o próprio macOS remove os modelos.

Nunca mexe em Documentos, Mesa, Fotos, Mail, iCloud, projetos ou bibliotecas do Resolve.
Só apaga dentro de pastas conhecidas de cache, mídias do WhatsApp e modelos de IA.

## Compilar a partir do código

Precisa só das Command Line Tools do Xcode (`xcode-select --install`).

```
./build.sh
```

O app sai em `build/Busca Busca Limpa Limpa.zip`.

Para ver o que seria limpo sem apagar nada:
`"/Applications/Busca Busca Limpa Limpa.app/Contents/MacOS/LimpaLimpa" --scan`
