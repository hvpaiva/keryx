# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'keryx'
require_relative 'support/system_check'

Warning[:deprecated] = true

require 'minitest/autorun'

Dir[File.expand_path('support/*.rb', __dir__)].each { require it }
