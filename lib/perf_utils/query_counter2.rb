# Derived from code found in http://stackoverflow.com/questions/5490411/counting-the-number-of-queries-performed


class QueryCounter2
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

  IGNORED_STATEMENTS = %w(CACHE SCHEMA).freeze
  OTHER_SQL = ["ROLLBACK", "BEGIN", "COMMIT"].freeze

  attr_accessor :queries, :queries_timing
  attr_accessor :other_hits, :other_timing
  def callback(_name, start, finish, _id, payload)
    if IGNORED_STATEMENTS.include?(payload[:name]) ||
         (payload[:name].nil? && OTHER_SQL.include?(payload[:sql]))
      @other_hits += 1
      @other_timing += (finish - start)
    else
      @queries += 1
      @queries_timing += (finish-start)
    end
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
    "<QueryCounter2 queries=#{@queries} [#{@queries_timing}]#{" other_hits=#{@other_hits} #{@other_timing}" if @other_hits > 0} >"
  end
  alias_method :to_s, :inspect
end
