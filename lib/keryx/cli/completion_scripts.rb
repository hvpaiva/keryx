# frozen_string_literal: true

module Keryx
  module CLI
    module CompletionScripts
      SHELLS = %w[bash zsh fish].freeze

      def self.render(shell, program)
        { 'bash' => method(:bash), 'zsh' => method(:zsh), 'fish' => method(:fish) }.fetch(shell).call(program)
      end

      def self.bash(program)
        <<~BASH
          # bash completion for #{program}. Load it with: eval "$(#{program} completion bash)"
          # or save it as ${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/#{program}
          _#{program}() {
              local out line
              COMPREPLY=()
              out=$("${COMP_WORDS[0]}" __complete "${COMP_WORDS[@]:1:COMP_CWORD-1}" "${COMP_WORDS[COMP_CWORD]}" 2>/dev/null) ||
                  return 0
              while IFS= read -r line; do
                  [[ -n $line ]] && COMPREPLY+=("$line")
              done <<<"$out"
          }
          complete -o default -F _#{program} #{program}
        BASH
      end

      def self.zsh(program)
        <<~ZSH
          #compdef #{program}
          # zsh completion for #{program}. Save it as _#{program} in a directory on your fpath, or load
          # it with: source <(#{program} completion zsh)
          _#{program}() {
              local -a candidates
              candidates=("${(@f)$(${words[1]} __complete "${(@)words[2,CURRENT-1]}" "${words[CURRENT]}" 2>/dev/null)}")
              candidates=(${candidates:#})
              if (( ${#candidates} )); then
                  compadd -a candidates
              else
                  _files
              fi
          }

          if [[ "$funcstack[1]" == "_#{program}" ]]; then
              _#{program} "$@"
          else
              compdef _#{program} #{program}
          fi
        ZSH
      end

      def self.fish(program)
        <<~FISH
          # fish completion for #{program}. Save it as ~/.config/fish/completions/#{program}.fish
          function __#{program}_complete
              set -l tokens (commandline -opc)
              set -e tokens[1]
              #{program} __complete $tokens (commandline -ct) 2>/dev/null
          end
          complete -c #{program} -f -a '(__#{program}_complete)'
        FISH
      end
    end
  end
end
