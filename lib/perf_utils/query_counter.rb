# Derived from code found in http://stackoverflow.com/questions/5490411/counting-the-number-of-queries-performed

require 'set' ##
$done = false ##

class QueryCounter
  def self.count(&block)
    new.count(&block)
  end

  def self.track(&block)
    new.track(&block)
  end

  def initialize
    @queries = 0
    @other_hits = 0

    @queries_timing = 0
    @other_timing = 0

    ## @per_query_counts = Hash.new { |h, n| h[n] ||= 0 }
    ## @other_statements = Set.new
  end

  attr_accessor :queries, :queries_timing
  attr_accessor :other_hits, :other_timing
  attr_accessor :names
  def callback(_name, start, finish, _id, payload)
    #byebug unless payload[:name] == "SCHEMA" || $done
    case payload[:name]
    when "SCHEMA", "CACHE", nil # ROLLBACK, BEGIN, END
      @other_hits += 1
      @other_timing += (finish - start)
      ## @other_statements << (payload[:name] || payload[:sql])
      args = (payload[:binds] || []).map { |a| a[1] }
      # puts "#{payload[:name]}: #{payload[:sql]}, #{args.inspect}"
    else
      @queries += 1
      @queries_timing += (finish-start)
      # byebug if payload[:binds].first.kind_of?(Array) && payload[:binds].first.size != 2
      # args = (payload[:binds] || []).map { |a| a[1] }
      # puts "#{payload[:name]}: #{payload[:sql]}, #{args.inspect}"
      ## @per_query_counts[[payload[:sql], args]] += 1
    end
#  rescue => e
#    byebug
  end

  def callback_proc
    lambda(&method(:callback))
  end

  def count(&block)
    track(&block)
    @queries
  end

  def track(&block)
    ActiveSupport::Notifications.subscribed(callback_proc, 'sql.active_record', &block)
    self
  end

  def to_i
    @queries
  end

  def inspect
    "<QueryCounter queries=#{@queries} [#{@queries_timing}]#{" other_hits=#{@other_hits} #{@other_timing}" if @other_hits > 0} >"
  end
  alias_method :to_s, :inspect
end
