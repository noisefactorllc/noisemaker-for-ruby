# frozen_string_literal: true

# Port of noisemaker-for-cpu test/dsl-let-order.test.js, adapted to the Ruby
# API. Mirrors upstream commit 9cc041d0 (statement-order lets): a chain sees
# only the lets declared at or before its own statement index, a later let of
# the same name reassigns it for later chains, and reading a pending name
# reports S003. Lets may still refer to each other in any order.

require "minitest/autorun"
require "json"
require_relative "../lib/noisemaker_cpu/dsl"

D = NoisemakerCpu::DSL unless defined?(D)
EFFECTS = JSON.parse(
  File.binread(File.expand_path("../lib/noisemaker_cpu/bundle/metadata.json", __dir__))
)["effects"] unless defined?(EFFECTS)

def compile(source)
  D.compile_dsl(source, EFFECTS)
end

def error_message
  yield
  ""
rescue StandardError => e
  e.message
end

class TestDslLetOrder < Minitest::Test
  def test_a_chain_uses_the_latest_let_declared_before_it_and_reassignment_is_allowed
    program = compile(<<~DSL)
      search synth
      let x = 10
      noise(scaleX: x).write(o0)
      let x = 90
      noise(scaleX: x).write(o1)
    DSL
    assert_equal 10, program["chains"][0]["steps"][0]["params"]["scaleX"]
    assert_equal 90, program["chains"][1]["steps"][0]["params"]["scaleX"]
  end

  def test_a_chain_reading_a_let_declared_by_a_later_statement_reports_s003
    message = error_message do
      compile(<<~DSL)
        search synth
        noise(scaleX: x).write(o0)
        let x = 20
      DSL
    end
    assert_match(/Variable used before assignment: 'x'/, message)
  end

  def test_a_let_may_reference_a_later_let_inside_its_value_expression
    program = compile(<<~DSL)
      search synth
      let a = b + 1
      let b = 5
      noise(scaleX: a).write(o0)
    DSL
    assert_equal 6, program["chains"][0]["steps"][0]["params"]["scaleX"]
  end

  def test_a_bare_identifier_naming_a_later_let_reports_s003_at_declaration
    message = error_message do
      compile(<<~DSL)
        search synth
        let a = b
        let b = 5
        noise(scaleX: a).write(o0)
      DSL
    end
    assert_match(/Variable used before assignment: 'b'/, message)
  end

  def test_a_value_call_may_reference_a_later_let_in_its_arguments
    program = compile(<<~DSL)
      search synth
      let outer = osc(type: oscKind.sine, speed: inner)
      let inner = osc(type: oscKind.tri, speed: 2)
      noise(scaleX: outer).write(o0)
    DSL
    descriptor = program["chains"][0]["steps"][0]["params"]["scaleX"]
    assert_equal "Oscillator", descriptor["type"]
    assert_equal 0, descriptor["oscType"]
    assert_equal "Oscillator", descriptor["speed"]["type"]
    assert_equal 1, descriptor["speed"]["oscType"]
    assert_equal 2, descriptor["speed"]["speed"]
  end

  def test_a_cyclic_let_set_fails_with_a_cycle_report
    message = error_message do
      compile(<<~DSL)
        search synth
        let a = b + 1
        let b = a + 1
        noise(scaleX: a).write(o0)
      DSL
    end
    assert_match(/Automation cycle detected: a -> b -> a/, message)
  end

  def test_a_let_whose_bare_identifier_names_nothing_resolvable_reports_s003_at_declaration
    message = error_message do
      compile(<<~DSL)
        search synth
        let y = x
        noise().write(o0)
      DSL
    end
    assert_match(/Variable used before assignment: 'x'/, message)
  end
end
