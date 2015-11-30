require 'benchmark'
require 'objspace'
require 'singleton'

# external
#require 'miq-process'
#require 'vmdb/logging'

class Bookend
  include Singleton

  def _log
    @log_instance
  end

  def initialize
    @log_instance = VMDBLogger.new(Rails.root.join("log").join("performance.log"))
  end

  def track(name)
    #_log.info("track #{name}")
    start_stat = gc_stat_hash
    ret_value = nil
    # time elapsed, memory used, queries performed, objects created
    tr = QueryCounter.track { ret_value = yield }

    gc_stat = gc_stat_hash
    diff_stat = stat_diff(start_stat, gc_stat)
    elapsed_time = diff_stat[:time]
    queries_time = tr ? tr.queries_timing : 0
    queries      = tr ? tr.queries : "ERROR"
    other_time   = tr ? tr.other_timing : 0
    other_hits   = tr ? tr.other_hits : "ERROR"
    code_time    = elapsed_time - queries_time - other_time

    # probably remove number for +obj:%10s
    message = "%-30sms:%5s sql[%4s]%4s o[%3s]%3s mem:%12s obj:%10s/%8s/%8s" %
      [ indent(name),       colon(code_time),
        queries,    colon(queries_time),
        other_hits, colon(other_time),
        coma(diff_stat[:memsize_of_all]),
        coma(diff_stat[:total_allocated_objects]),
        coma(diff_stat[:old_objects]),
        coma(diff_stat[:total_freed_objects]),
#        coma(gc_stat[:memory_usage]),
#        coma(gc_stat[:memory_size])
      ]
    _log.info(message)
    ret_value
  end

  # timing
  def colon(d) # comes in ms
    return "0" if d.nil? || d == 0
    coma(d.to_f * 1_000).to_i.to_s
  end

  def coma(d)
    d.to_s.gsub(/(\d)(?=(\d\d\d)+(?!\d))/, "\\1_")
  end

  # ruby_gc_logger
  def gc_stat_hash
    mp = MiqProcess.processInfo
    gc_stat = GC.stat
    live_objects  = gc_stat[:total_allocated_objects] - gc_stat[:total_freed_objects] ## need to revisit this one
    young_objects = live_objects - gc_stat[:old_objects]
      # ObjectSpace.count_objects.values_at(*count_objects_keys) +
      # ObjectSpace.count_objects_size.values_at(*count_objects_size_keys)
  {
    :time                                    => Time.now,
    :total_allocated_objects                 => gc_stat[:total_allocated_objects],
    :total_freed_objects                     => gc_stat[:total_freed_objects],
    :old_objects                             => gc_stat[:old_objects],
    :live_objects                            => live_objects,
    :young_objects                           => young_objects,
    :memsize_of_all                          => ObjectSpace.memsize_of_all,
    :memory_usage                            => mp[:memory_usage], # rss
    :memory_size                             => mp[:memory_size],  # vsize
#    :count                                   => gc_stat[:count],
    # :heap_allocated_pages                    => gc_stat[:heap_allocated_pages],
    # :heap_sorted_length                      => gc_stat[:heap_sorted_length],
    # :heap_allocatable_pages                  => gc_stat[:heap_allocatable_pages],
    # :heap_available_slots                    => gc_stat[:heap_available_slots],
    # :heap_live_slots                         => gc_stat[:heap_live_slots],
    # :heap_free_slots                         => gc_stat[:heap_free_slots],
    # :heap_final_slots                        => gc_stat[:heap_final_slots],
    # :heap_marked_slots                       => gc_stat[:heap_marked_slots],
    # :heap_swept_slots                        => gc_stat[:heap_swept_slots],
    # :heap_eden_pages                         => gc_stat[:heap_eden_pages],
    # :heap_tomb_pages                         => gc_stat[:heap_tomb_pages],
    # :total_allocated_pages                   => gc_stat[:total_allocated_pages],
    # :total_freed_pages                       => gc_stat[:total_freed_pages],
    # :total_allocated_objects                 => gc_stat[:total_allocated_objects],
    # :total_freed_objects                     => gc_stat[:total_freed_objects],
    # :malloc_increase_bytes                   => gc_stat[:malloc_increase_bytes],
    # :malloc_increase_bytes_limit             => gc_stat[:malloc_increase_bytes_limit],
    :minor_gc_count                          => gc_stat[:minor_gc_count],
    :major_gc_count                          => gc_stat[:major_gc_count],
    # :remembered_wb_unprotected_objects       => gc_stat[:remembered_wb_unprotected_objects],
    # :remembered_wb_unprotected_objects_limit => gc_stat[:remembered_wb_unprotected_objects_limit],
    # :old_objects                             => gc_stat[:old_objects],
    # :old_objects_limit                       => gc_stat[:old_objects_limit],
    # :oldmalloc_increase_bytes                => gc_stat[:oldmalloc_increase_bytes],
    # :oldmalloc_increase_bytes_limit          => gc_stat[:oldmalloc_increase_bytes_limit],
  }
  end

  def stat_diff(first, last)
    last.each_with_object({}) do |(n, v), h|
      h[n] = v - first[n]
    end
  end
  def self.track(name, &block)
    instance.track(name, &block)
  end
end

def thrice(name, count = 1, &block)
  bookend("prep #{name}", &block)
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
  if method.kind_of?(Symbol)
    define_method("#{method}_with_bookend") do |*args|
      Bookend.track(name||method) { send("#{method}_without_bookend", *args) }
    end
    alias_method_chain method, :bookend
  else
    Bookend.track(name||method, &block)
  end
end

def thrice(name, count = 1, &block)
  bookend("prep #{name}", &block)
  GC.start
  if count != 1
    4.times { |i| bookend("#{count if count != 1} #{name} #{i + 1}") { count.times(&block) } }
  else
    4.times { |j| bookend("#{count if count != 1} #{name} #{j + 1}", &block) }
  end
end

def thrices(name, count = 1, pre = true, &block)
  sandbook("prep #{name}", &block) if pre
  GC.start
  if count != 1
    4.times { |i| sandbook("#{count if count != 1} #{name} #{i + 1}") { count.times(&block) } }
  else
    4.times { |j| sandbook("#{count if count != 1} #{name} #{j + 1}", &block) }
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
QueryCounter.track { Metric::Capture.perf_capture_health_check }
bookend("perf_capture_health_check") do
  Metric::Capture.perf_capture_health_check
end
end
