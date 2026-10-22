# frozen_string_literal: true

require_relative '../text'

module Keryx
  module CLI
    module Table
      GAP = '   '

      module_function

      def render(terminal, headers, rows)
        cells = [headers.map { [:header, it] }, *rows.map { |row| row.map { plain(it) } }]
        widths = headers.each_index.map { |column| cells.map { it[column][1].size }.max }
        cells.map { |row| line(terminal, row, widths) }
      end

      def plain(cell) = cell.is_a?(Array) ? [cell[0], Text.plain(cell[1])] : [nil, Text.plain(cell)]

      def line(terminal, row, widths)
        row.each_with_index.map do |(role, text), column|
          padded = column == row.size - 1 ? text : text.ljust(widths[column])
          role ? padded.sub(text) { terminal.paint(role, text) } : padded
        end.join(GAP).rstrip
      end
    end
  end
end
