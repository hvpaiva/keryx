# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../harness'
require_relative '../spawned'
require_relative '../text'
require_relative 'join'
require_relative 'spawn'

module Keryx
  module Commands
    class Expect < CLI::Command
      # A letter or digit first, so that herdr never reads the id as one of its flags.
      PANE = /\A[A-Za-z0-9][!-~]{0,63}\z/
      REVIVE = "bring it back with 'keryx join %s --revive' from the session that will hold it"

      define 'expect', section: 'Session Commands', arguments: 'ADDRESS', min: 1, max: 1,
                       summary: 'Expect a session another launcher starts, with this address for its director',
                       description: 'Prepare ADDRESS for an agent session that a launcher of your own starts in a ' \
                                    "herdr pane, with the address this command acts as for the session's director, " \
                                    'as keryx spawn does for the sessions it starts. Run it after the pane exists ' \
                                    "and before the harness starts in it.\n\n" \
                                    'ADDRESS is MEMBER.TEAM, or MEMBER alone for a member of the team of the ' \
                                    'address this command acts as, and it is created if it does not exist. expect ' \
                                    'refuses an address in a reserved scope (NAME.local is a person at a terminal ' \
                                    'and keryx.system is keryx itself), on another machine or of one session, a ' \
                                    "retired address, and an address another live session holds.\n\n" \
                                    'expect records the director with the harness, the herdr socket and the pane, ' \
                                    'after herdr confirms the pane is there. The first session to join ADDRESS ' \
                                    'takes that director only when it runs that harness in that pane on that ' \
                                    'socket, however late it joins, and that first join removes the record, ' \
                                    "whoever makes it. 'keryx who -o json' gives the record as spawned until then, " \
                                    "and the session's director once it joined.\n\n" \
                                    'Running expect again with the same harness, pane, socket and director changes ' \
                                    'nothing and succeeds, even after that session joined, so a launcher that does ' \
                                    'not know whether an earlier run finished can run it again. A different record ' \
                                    'waiting at ADDRESS, from expect or from keryx spawn, is refused unless ' \
                                    '--replace is given. keryx spawn of the same address replaces what expect ' \
                                    "recorded.\n\n" \
                                    'The director is the address this command acts as, the one this session holds ' \
                                    'or the one --as or KERYX_AS names, or your NAME.local from a plain terminal; ' \
                                    "'keryx --help' says which addresses an agent session may act as. The session " \
                                    "gives its own role and ceiling to 'keryx join'. The address takes mail before " \
                                    "its session joins, so a first request can go with 'keryx ask' as soon as expect " \
                                    'returns and waits in the mailbox. keryx reports no dialog the harness stops at ' \
                                    'before its join, as it does while spawn waits; who -o json gives the pane to ' \
                                    'look at.',
                       examples: [['Expect a Claude session in pane w1:p3, with this session for its director',
                                   'expect rev-1.alpha --harness claude --pane w1:p3'],
                                  ['Expect a Codex session on another herdr server, directed by orq.alpha',
                                   'expect impl.alpha --harness codex --pane w2:p1 ' \
                                   '--socket /run/user/1000/herdr.sock --as orq.alpha'],
                                  ['Expect the session in a new pane instead of the one an abandoned opening recorded',
                                   'expect rev-1.alpha --harness claude --pane w1:p4 --replace']]

      def define_options(parser)
        parser.on('--harness HARNESS', Harness::KINDS, 'Expect claude, codex or cursor (required)') do |harness|
          options[:harness] = harness
        end
        parser.on('--pane PANE', 'Expect the session in herdr pane PANE, such as w1:p3 (required)') do |pane|
          options[:pane] = pane
        end
        socket = 'Expect it on the herdr server whose socket is PATH (default: HERDR_SOCKET_PATH)'
        parser.on('--socket PATH', socket) { options[:socket] = it }
        parser.on('--replace', 'Replace a different record waiting at the address') { options[:replace] = true }
        output_option(parser)
      end

      def call(arguments)
        name = Join.resolve(app, arguments.first, -> { app.own_address })
        spawned = expected
        app.herdr.pane(spawned.herdr_socket, spawned.herdr_pane)
        outcome, waiting = app.store.with_occupants_lock { claim(name, spawned) }
        json? ? print_json(record(name, spawned, outcome)) : report(name, spawned, outcome, waiting)
      end

      private

      # The usage errors come before the director, which can create the person's address.
      def expected
        harness = options[:harness] or raise UsageError, 'missing --harness: give claude, codex or cursor'
        pane = herdr_pane
        socket = herdr_socket
        Spawned.new(director: app.me, harness:, herdr_socket: socket, herdr_pane: pane)
      end

      def herdr_pane
        pane = options[:pane] or raise UsageError, 'missing --pane: give the herdr pane the session starts in'
        return pane if PANE.match?(pane)

        raise UsageError, "invalid pane #{pane.inspect}: a letter or digit, then up to 63 printable ASCII characters " \
                          'without spaces'
      end

      # Kept as given, since the join compares it with the HERDR_SOCKET_PATH herdr gives the session's pane.
      def herdr_socket
        socket = options[:socket] || app.caller.herdr_socket or
          raise UsageError, 'missing --socket: give the path of the herdr server, or run expect in a herdr pane'
        return socket if socket.start_with?('/')

        raise UsageError, "invalid socket #{socket.inspect}: give an absolute path"
      end

      # Under the lock join takes, so a join either comes first, and these checks see its session, or finds the record.
      def claim(name, spawned)
        Join.refuse_retired(app, name, format(REVIVE, name))
        return [:joined, nil] if joined?(name, spawned)

        Join.refuse_taken(app, name, Spawn::FREE)
        app.store.create_address(name)
        waiting = app.store.record_spawned(name, spawned, replace: options.fetch(:replace, false))
        [outcome(name, spawned, waiting), waiting]
      end

      # The session expected took the director when it joined, and its join removed the record.
      def joined?(name, spawned)
        occupant = app.store.occupant(name)
        !occupant.nil? && spawned.started?(occupant) && occupant.director == spawned.director &&
          app.roster.live?(occupant)
      end

      def outcome(name, spawned, waiting)
        return :recorded unless waiting
        return :unchanged if waiting == spawned
        return :replaced if options[:replace]

        raise Error, "#{app.full(name)} already expects a #{described(waiting, socket: true)}; pass --replace to " \
                     'expect this one instead'
      end

      def described(spawned, socket: false)
        place = socket ? " of #{Text.plain(spawned.herdr_socket)}" : ''
        "#{spawned.harness} session in pane #{Text.plain(spawned.herdr_pane)}#{place}, directed by " \
          "#{app.full(spawned.director)}"
      end

      def record(name, spawned, outcome)
        { 'address' => app.full(name), 'outcome' => outcome.to_s, **spawned.record,
          'director' => app.full(spawned.director) }
      end

      def report(name, spawned, outcome, waiting)
        address = terminal.paint(:address, app.full(name))
        case outcome
        when :unchanged then terminal.puts("#{address} already expects a #{described(spawned)}.")
        when :joined then terminal.puts("#{address} already joined as the #{described(spawned)}.")
        else
          terminal.puts("Expecting #{address} as a #{spawned.harness} session in pane " \
                        "#{Text.plain(spawned.herdr_pane)}; it takes #{app.full(spawned.director)} for its director " \
                        'when it joins.')
          terminal.puts("It replaces the record of a #{described(waiting, socket: true)}.") if outcome == :replaced
        end
      end
    end
  end
end
