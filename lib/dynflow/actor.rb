module Dynflow

  module MethodicActor
    def on_message(message)
      method, *args = message
      self.send(method, *args)
    end
  end

  # Extend the Concurrent::Actor::Envelope to include information about the origin of the message
  module EnvelopeBacktraceExtension
    def initialize(*args)
      super
      @origin_backtrace = caller + Actor::BacktraceCollector.current_actor_backtrace
    end

    def origin_backtrace
      @origin_backtrace
    end

    def inspect
      "#<#{self.class.name}:#{object_id}> @message=#{@message.inspect}, @sender=#{@sender.inspect}, @address=#{@address.inspect}>"
    end
  end
  Concurrent::Actor::Envelope.prepend(EnvelopeBacktraceExtension)

  # Common parent for all the Dynflow actors defining some defaults
  # that we preffer here.
  class Actor < Concurrent::Actor::Context
    module LogWithFullBacktrace
      def log(level, message = nil, &block)
        if message.is_a? Exception
          error = message
          backtrace = Actor::BacktraceCollector.full_backtrace(error.backtrace)
          log(level, format("%s (%s)\n%s", error.message, error.class, backtrace.join("\n")))
        else
          super
        end
      end
    end

    class SetResultsWithOriginLogging < Concurrent::Actor::Behaviour::SetResults
      include LogWithFullBacktrace

      def on_envelope(envelope)
        Actor::BacktraceCollector.with_backtrace(envelope.origin_backtrace) { super }
      end
    end

    class BacktraceCollector
      CONCURRENT_RUBY_LINE = '[ concurrent-ruby ]'.freeze

      class << self
        def with_backtrace(backtrace)
          previous_actor_backtrace = Thread.current[:_dynflow_actor_backtrace]
          Thread.current[:_dynflow_actor_backtrace] = backtrace
          yield
        ensure
          Thread.current[:_dynflow_actor_backtrace] = previous_actor_backtrace
        end

        def current_actor_backtrace
          Thread.current[:_dynflow_actor_backtrace] || []
        end

        def full_backtrace(backtrace)
          filter_backtrace((backtrace || []) + current_actor_backtrace)
        end

        private

        def filter_line?(line)
          %w[concurrent-ruby gems/logging actor.rb].any? { |pattern| line.include?(pattern) }
        end

        # takes an array of backtrace lines and replaces each chunk
        def filter_backtrace(backtrace)
          backtrace.map { |line| filter_line?(line) ? CONCURRENT_RUBY_LINE : line }
            .chunk_while { |l1, l2| l1.equal?(CONCURRENT_RUBY_LINE) && l2.equal?(CONCURRENT_RUBY_LINE) }
            .map(&:first)
        end
      end
    end

    include LogWithFullBacktrace
    include MethodicActor

    # Behaviour that watches for polite asking for termination
    # and calls corresponding method on the context to do so
    class PoliteTermination < Concurrent::Actor::Behaviour::Abstract
      def on_envelope(envelope)
        message, terminated_future = envelope
        if :start_termination == message
          context.start_termination(terminated_future)
          envelope.future.fulfill true if !envelope.future.nil?
          Concurrent::Actor::Behaviour::MESSAGE_PROCESSED
        else
          pass envelope
        end
      end
    end

    include Algebrick::Matching

    def start_termination(future)
      @terminated = future
    end

    def finish_termination
      @terminated.fulfill(true)
      reference.tell(:terminate!)
    end

    def terminating?
      !!@terminated
    end

    def behaviour_definition
      [*Concurrent::Actor::Behaviour.base(:just_log),
       Concurrent::Actor::Behaviour::Buffer,
       [SetResultsWithOriginLogging, :just_log],
       Concurrent::Actor::Behaviour::Awaits,
       PoliteTermination,
       Concurrent::Actor::Behaviour::ExecutesContext,
       Concurrent::Actor::Behaviour::ErrorsOnUnknownMessage]
    end
  end
end
