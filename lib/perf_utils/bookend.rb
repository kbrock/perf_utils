require 'objspace'
require 'singleton'
require 'json'
require 'perf_utils/rack_storage'
require 'perf_utils/printer'

class Bookend
  include Singleton

  def initialize
  end

  def self.track(name, &block)
    instance.track(name, &block)
  end

  def self.config(name, options = nil)
    name, options = :printer, name if options.nil?
    if options.kind_of?(Hash)
      instance.config(name, options)
    else
      instance.config(name, options)
    end
  end

  # profile(klass, method_name)
  # profile([[klass, method_name], ...])
  def self.profile(methods, name = nil)
    methods = [[methods, name]] if name
    methods.each do |klass1, method|
      possible_klasses = [klass1, (klass1.const_get(:ClassMethods) rescue nil)]
      assigned = possible_klasses.compact.map do |klass|
        if klass.respond_to?(method)
          #puts "binding #{"#{klass.name}.#{method}"}"
          ::Rack::MiniProfiler.profile_singleton_method(klass, method) { |a| name || "#{klass.name}.#{method}" }
          true
        elsif klass.method_defined?(method)
          #puts "binding #{"#{klass.name}##{method}"}"
          ::Rack::MiniProfiler.profile_method(klass, method) { |a| name || "#{klass.name}##{method}" }
          true
        end
      end
      puts "Can not bind: #{klass.name}.#{method}" unless assigned.any?
    end
  end

  def self.profile_method(klass, method)
    ::Rack::MiniProfiler.profile_method(klass, method) { |a| name || "#{klass.name}##{method}" }
  end

  def self.profile_klass(klass, method)
    ::Rack::MiniProfiler.profile_singleton_method(klass, method) { |a| name || "#{klass.name}.#{method}" }
  end

  def self.print(ids)
    instance.print(Array.wrap(ids))
  end

  def capture(name, options = {})
    base_url = options[:base_url] || "http://localhost:3000"
    # base_file = options[:base_file] || defined?(Rails) ? Rails.root.join("public") : "."
    env = {'RACK_MINI_PROFILER_ORIGINAL_SCRIPT_NAME' => base_url}

    page_struct = storage.current(env).page_struct
    #page_struct[:user] = config.user_provider.call(env) # needed?
    page_struct[:name] = name
    d = PerfUtils::Stat.new(name).calc
    yield
    d.delta
    page_struct[:root].record_time(d.time * 1000)

#    storage.set_unviewed(page_struct[:user], page_struct[:id])
    storage.save(page_struct)
    [page_struct[:id], d]
  ensure
    ::Rack::MiniProfiler.current = nil
  end

  def print(pages, stats = nil)
    pages = Array.wrap(pages).map { |id| storage.load(id) }
    page_groups = pages.group_by { |page| page[:name] =~ /^(.*[^0-9])[0-9]+$/ ; $1 }.values
    printer.print_group(page_groups, stats)
  end

  def print_xs(xs)
    stats = xs.map(&:last)
    x = xs.map(&:first) #process ids
    if true
      print(x, stats)
      puts
    else
      puts
      puts "beer gen_perf #{x}"
    end
    x
  end

  # config

  def printer
    @printer ||= ::PerfUtils::Printer.new.tap do |printer|
      printer.display_children = false
      printer.display_sql = true
      printer.shorten = true
      printer.display_stats = true
    end
  end

  def storage
    @storage ||= ::PerfUtils::RackStorage.new
  end

  def config(obj, params)
    target = public_send(obj)
    if params.kind_of?(Hash)
      params.each { |n, v| target.public_send("#{n}=", v) }
    else
      target.public_send(params)
    end
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

def bookend(name = "no name", count = 1, &block)
  gp = Bookend.instance
  # [[gen_perf_num, stat]]
  xs = count.times.collect do |i|
    gp.capture("#{name}-#{i+1}", &block)
  end
  gp.print_xs(xs)
  xs.map(&:first) #process ids
end

def sandy(name = "", count = 4, &block)
  gp = Bookend.instance
  old_skip = Bookend.config(:skip_first)
  Bookend.config(:skip_first => true)
  # [[gen_perf_num, stat]]
  xs = count.times.collect do |i|
    x_s = nil
    begin
      Vm.transaction do
        x_s = gp.capture("#{name}-#{i+1}", &block)
        raise "rolling back transaction"
      end
    rescue => e
      puts "bailed with #{e.message}"
    end
    x_s
  end
  gp.print_xs(xs)
  xs.map(&:first) #process ids
ensure
  Bookend.config(:skip_first => old_skip)
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

Metric::Capture::perf_capture_timer
end
