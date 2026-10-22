# frozen_string_literal: true

module Keryx
  module CLI
    module Table
      GAP = '   '

      module_function

      def render(terminal, headers, rows)
        cells = [headers.map { [:header, it] }, *rows.map { |row| row.map { it.is_a?(Array) ? it : [nil, it.to_s] } }]
        widths = headers.each_index.map { |column| cells.map { it[column][1].size }.max }
        cells.map { |row| line(terminal, row, widths) }
      end

      def line(terminal, row, widths)
        row.each_with_index.map do |(role, text), column|
          padded = column == row.size - 1 ? text : text.ljust(widths[column])
          role ? padded.sub(text) { terminal.paint(role, text) } : padded
        end.join(GAP).rstrip
      end
    end
  end
end
