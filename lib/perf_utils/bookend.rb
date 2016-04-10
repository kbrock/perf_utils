require 'benchmark'
require 'objspace'
require 'singleton'
require 'logger'
require 'json'

# external
#require 'miq-process'
#require 'vmdb/logging'

class Bookend
  class SimpleFormatter < Logger::Formatter
    def format_datetime(time)
      time.strftime("%H:%M:%S.%6N")
    end

    def call(severity, time, progname, msg)
      # #{format_datetime(time)}
      "#{msg2str(msg)}\n"
    end
  end
  class StackFrame
    attr_accessor :name
    # @return [Array<String>] parents names of parent stack frames
    attr_accessor :parent
    attr_accessor :start_stat
    attr_accessor :end_stat
    # in the future, store these values in the hash - have it directly add to this frame
    attr_accessor :tr

    def initialize(name, parent, collect_stat = false)
      @name = name
      @parent = parent # strings for now
      @start_stat = self.class.gc_stat_hash if collect_stat
    end

    def full_name
      @full_name ||= traverse.map(&:name).reverse.join(":")
    end

    def diff_stat
      @diff_stat ||= @end_stat.each_with_object({}) do |(n, v), h|
        h[n] = v - @start_stat[n]
      end
    end

    def elapsed_time            ; diff_stat[:time] ; end
    def memsize_of_all          ; diff_stat[:memsize_of_all] ; end
    def total_allocated_objects ; diff_stat[:total_allocated_objects] ; end
    def old_objects             ; diff_stat[:old_objects] ; end
    def total_freed_objects     ; diff_stat[:total_freed_objects] ; end
    #def memory_usage            ; diff_stat[:memory_usage] ; end
    def rss                     ; diff_stat[:rss] ; end

    def elapsed_time            ; diff_stat[:time] ; end
    def queries_time            ; tr ? tr.queries_timing : 0 ; end
    def queries                 ; tr ? tr.queries : "ERROR" ; end
    def other_time              ; tr ? tr.other_timing : 0 ; end
    def other_hits              ; tr ? tr.other_hits : "ERROR" ; end
    def code_time               ; elapsed_time - queries_time - other_time ; end

  # -- execution

    def track(*args)
      @start_stat = self.class.gc_stat_hash
      yield(*args)
    ensure
      @end_stat = self.class.gc_stat_hash
    end

      # ruby_gc_logger
    def self.gc_stat_hash
    gc_stat = GC.stat
    live_objects  = gc_stat[:total_allocated_objects] - gc_stat[:total_freed_objects] ## need to revisit this one
    young_objects = live_objects - gc_stat[:old_objects]
    {
      :time                                    => Time.now,
      :total_allocated_objects                 => gc_stat[:total_allocated_objects],
      :total_freed_objects                     => gc_stat[:total_freed_objects],
      :old_objects                             => gc_stat[:old_objects],
      :young_objects                           => young_objects,
      :memsize_of_all                          => ObjectSpace.memsize_of_all,
    }
    end

    private

    def traverse
      return enum_for(:traverse) unless block_given?
      yield self
      p = parent
      while(p)
        yield p
        p = p.parent
      end
    end
  end

  include Singleton

  def _log
    @log_instance
  end

  def initialize
    @log_instance = Logger.new(Rails.root.join("log").join("performance.log"))
    @log_instance.level = Logger::DEBUG
    @log_instance.formatter = ::Bookend::SimpleFormatter.new
  end

  def mark(message)
    _log.info(message)
  end

  attr_accessor :frame

  def track(name)
    @frame = StackFrame.new(name, @frame, true)
    Rails.logger.info("bookend: begin #{@frame.full_name}")
    ret_value = nil
    frame.tr = QueryCounter2.track { ret_value = yield }
    frame.end_stat = StackFrame.gc_stat_hash # TODO: will be part of frame.track

    message = "%-34s%5sms %6sq[%8sms] %12sb %10sobj/%7s/%8s" %
      [ frame.full_name,       colon(frame.code_time),
        "#{frame.queries}+#{frame.other_hits}",
        "#{colon(frame.queries_time)}+#{colon(frame.other_time)}",
        coma(frame.memsize_of_all),
        coma(frame.total_allocated_objects),
        coma(frame.old_objects),
        coma(frame.total_freed_objects),
      ]
    _log.info(message)
    Rails.logger.info("bookend: end   #{@frame.full_name} time: #{colon(frame.elapsed_time)}, " \
        "#{frame.queries}+#{frame.other_hits} ==> mem: #{coma(frame.memsize_of_all)} " \
        "obj: #{coma(frame.total_allocated_objects)}/#{coma(frame.old_objects)}/#{coma(frame.total_freed_objects)}")
    ret_value
  ensure
    @frame = @frame.try(:parent)
  end

  # timing
  def colon(d) # comes in ms
    return "0" if d.nil? || d == 0
    coma(d.to_f * 1_000).to_i.to_s
  end

  def coma(d)
    d.to_s.gsub(/(\d)(?=(\d\d\d)+(?!\d))/, "\\1_")
  end

  def self.mark(*args)
    instance.mark(*args)
  end

  def self.track(name, &block)
    instance.track(name, &block)
  end
end

def twice(name, count = 1, &block)
  Bookend.mark(":#{name}-0")
  Bookend.mark("------")
  yield
  GC.start
  Bookend.mark(":#{name} 1")
  Bookend.mark("------")
  yield
end

def thrice(name, count = 1, &block)
  bookend("#{"X " if count != 1}#{name}-0", &block)
  GC.start
  if count != 1
    4.times { |i| bookend("#{count} #{name}#{i + 1}") { count.times(&block) } }
  else
    4.times { |j| bookend("#{name}#{j + 1}", &block) }
  end
end

# bookend :method
# bookend :method, "metric_name"
# bookend("metric_name") { puts "here" }
def bookend(method = "noname", name = nil, &block)
  #track_name = (caller_location(0,4).map(&:) + []).join("/")
  helper_method = "#{method}_with_bookend"
  if method.kind_of?(Symbol)
    define_method(helper_method) do |*args|
      Bookend.track(name||method) { send("#{method}_without_bookend", *args) }
    end
    alias_method_chain method, :bookend
  else
    Bookend.track(name||method, &block)
  end
end

def thrice(name, count = 1, &block)
  bookend("#{name}-0", &block)
  GC.start
  if count != 1
    4.times { |i| bookend("#{count if count != 1} #{name} #{i + 1}") { count.times(&block) } }
  else
    4.times { |j| bookend("#{count if count != 1} #{name} #{j + 1}", &block) }
  end
end

def thrices(name, count = 1, pre = true, &block)
  sandbook("#{name}-0", &block) if pre
  GC.start
  if count != 1
    4.times { |i| sandbook("#{count if count != 1} #{name} #{i + 1}") { count.times(&block) } }
  else
    4.times { |j| sandbook("#{count if count != 1} #{name} #{j + 1}", &block) }
  end
end

def sandy(method = "", count = 4)
  count.times do |i|
    begin
      Bookend.mark("#{method} #{i}#{i ==0 ? "-pre" : ""}")
      Vm.transaction do
        yield
        raise "rolling back transaction"
      end
    rescue => e
      puts "bailed with #{e.message}"
    end
  end
end

def sandbook(method = "noname", &block)
  Vm.transaction do
    Bookend.track(method, &block)
    raise "rolling back transaction"
  end
rescue => e
  puts "bailed with #{e.message}"
end

def twosands(name = "no name", count = 2, open_all = nil, &block)
  gen = false
  if open_all.to_s =~ /gen/
    open_all = false
    gen = true
  end
  x = count.times.collect { |i| sand2("#{name}-#{i+1}", :normal, open_all.nil? ? i > 0 : open_all, &block) }.inspect
  puts "beer ./gen_perf.rb #{x}"
  puts `./gen_perf.rb #{x}` if gen
  x
end

def sand2(name = "no name", mode = :normal, open_url = true, &block)
  options = {
    :open => open_url == true, :json => true, :html => true,
    :base_url => 'http://localhost:3000',
    :base_file => Rails.root.join("public")
  }
  Rack::MiniProfiler.new(block, {}).run_to_file(name, options, &block)
end

def sandprof(name = "no name", &block)
  data = ::RubyProf::Profile.profile do
    yield
  end
   # ::RubyProf::FlatPrinter => 'flat.txt',
   # ::RubyProf::GraphPrinter => 'graph.txt',
   # ::RubyProf::GraphHtmlPrinter => 'graph.html',
  printer = ::RubyProf::CallStackPrinter.new(data)
  file_name = Rails.join("tmp/profile/#{name}-#{Time.now.strftime("%H:%M:%S")}-call_stack.html")
  ::File.open(file_name, 'wb') do |file|
    printer.print(file, {})
  end
end

if false

module Metric::Capture
  class << self
    bookend(:perf_capture_health_check)
    bookend(:perf_capture_timer)
    bookend(:calc_targets_by_rollup_parent)
    bookend(:calc_tasks_by_rollup_parent)
    bookend(:queue_captures)
  end
end

require 'miq-process'
Metric::Capture::perf_capture_timer

Bookend.track("perf_capture_health_check") { Metric::Capture.perf_capture_health_check }
QueryCounter2.track { Metric::Capture.perf_capture_health_check }
bookend("perf_capture_health_check") do
  Metric::Capture.perf_capture_health_check
end
end
