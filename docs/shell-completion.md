# Shell completion

keryx completes commands, flags, addresses and message ids in bash, zsh and fish. Save the script
for your shell where it loads on its own.

```sh
keryx completion bash > "${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/keryx"
keryx completion zsh > ~/.zfunc/_keryx   # with fpath+=~/.zfunc before compinit
keryx completion fish > ~/.config/fish/completions/keryx.fish
```

The scripts ask keryx for the candidates each time, so they stay current when keryx is updated.
The bash path is loaded by the bash-completion package. Without it, add
`eval "$(keryx completion bash)"` to `~/.bashrc` instead.
