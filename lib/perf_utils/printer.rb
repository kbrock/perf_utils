module PerfUtils
  class Printer
    attr_accessor :display_offset
    attr_accessor :display_sql
    attr_accessor :display_trivial
    attr_accessor :display_trace
    attr_accessor :collapse

    attr_accessor :aggressive_dedup
    attr_accessor :dedup
    attr_accessor :shorten
    attr_accessor :display_children
    attr_accessor :width

    attr_reader   :fmt_h, :fmt_d

    def initialize
      @display_offset = false
      @display_sql = false
      @display_children = false
      @collapse = []
    end

    def handle_width(phrases)
      widths = Array.wrap(phrases).map do |phrase|
        f_to_s(phrase).size
      end + [width, 0]

      @width = widths.compact.max
      @fmt_h = fmt(':')
      @fmt_d = fmt
    end

    def collapse=(val)
      @collapse = val.kind_of?(String) ? val.split(",") : val
    end

    def print_header
      print_line(0, "@", "ms", "ms-", "sql", "sqlms", "sqlrows", "comments")
      print_dashes
    end

    def print_dashes
      d = "---"
      print_line(0, d, d, d, d, d, d, d)
    end

    def print_page(page)
      query_count, row_count = child_sql_counts(page.root)
      print_line(0, 0.0, page.duration_ms, nil, query_count, page.duration_ms_in_sql, row_count, page[:name])
      collapse_nodes(page.root[:children], collapse) unless collapse.empty?
      print_node(page.root) if display_children
    end

    def collapse_nodes(children, collapse)
      return unless children
      children.each do |child|
        if collapse.detect { |c| child.name =~ /#{c}/ }
          merge_children(child)
        else
          collapse_nodes(child[:children], collapse)
        end
      end
    end

    # @param page_groups [Array<Page>,Array<Array<Page>>]
    def print_group(page_groups)
      pages = page_groups.flatten
      page_groups = [page_groups] unless page_groups.first.kind_of?(Array)

      handle_width(pages.map(&:duration_ms))
      handle_width(pages.map(&:duration_ms_in_sql))

      print_header

      page_groups.each do |partitions|
        if page_groups.size > 1
          puts "======"
          puts "#{partitions.first[:name]}"
          puts "======"
        end
        partitions.each { |page| print_page(page) }

        if partitions.size > 2
          print_dashes
          print_averages(partitions[1..-1])
        end
      end
    end

    def print_averages(pages)
      duration = avg(pages, &:duration_ms)
      counts = pages.map { |page| child_sql_counts(page) }
      query_times = avg(pages, &:duration_ms_in_sql)
      query_count = avg(counts, &:first)
      query_rows = avg(counts, &:last)
      print_line(0, nil, duration, nil, query_count, query_times, query_rows, "avg")
    end

    private

    def print_node(root)
      all_nodes(root, !display_trivial) do |node, _|
        query_count, query_rows = count_sql(node) #if !display_sql # unsure

        print_line(node[:depth], node[:start_milliseconds],
                   node[:duration_milliseconds], node[:duration_without_children_milliseconds],
                   query_count, node[:sql_timings_duration_milliseconds], query_rows,
                   node[:name].try(:strip))

        print_sqls(node[:sql_timings], node) if display_sql
      end
    end

    def trivial(node)
      node[:trivial_duration_threshold_milliseconds] &&
      node[:duration_milliseconds] < node[:trivial_duration_threshold_milliseconds] &&
      node[:sql_timings].size == 0
    end

    def print_sqls(snodes, node)
      snodes.each do |snode|
        snode[:summary] = summarize_sql_cmd(snode[:formatted_command_string], snode[:parameters], !aggressive_dedup)
      end

      snodes = dedup_sql(snodes, aggressive_dedup) if dedup || aggressive_dedup
      snodes.each do |snode|
        print_sql(snode, node[:depth] + 1)
        print_trace(snode[:stack_trace_snippet], node[:depth]) if display_trace
        # ? snode[:is_duplicate]
      end
    end

    def print_sql(snode, depth)
      start_ms = snode[:start_milliseconds]
      duration = snode[:duration_milliseconds] #.round(1) amount of time to fetch all nodes?
      #duration_f = snode[:first_fetch_duration_milliseconds].round(1) # amount of time to fetch first node
      row_count = snode[:row_count] # # rows returned
      summary  = shorten ? snode[:summary] : snode[:formatted_command_string] # shortened sql (custom)
      count    = snode[:count] # # times this was run (custom)

      print_line(depth, start_ms, nil, nil, count, duration, row_count, summary)
    end

    def print_trace(trace, depth)
      print_heading(depth, "TRACE:")
      trace.split("\n").each do |t|
        print_heading(depth + 1, t)
      end
    end

    def child_sql_counts(root)
      all_nodes(root, false, [0, 0], &method(:count_sql))
    end

    def count_sql(node, tgt = [0, 0])
      if (timings = node[:sql_timings])
        tgt[0] += timings.size
        tgt[1] += timings.map {|timing| timing[:row_count].to_i }.sum
      end
      tgt
    end

    def summarize_sql_cmd(sql, params, include_count = true)
      return "SCHEMA #{$1}" if sql =~ /pg_attribute a.*'"?([^'"]*)"?'::regclass/

      sql =~ /^ *(SELECT|UPDATE|DELETE|INSERT)/i #delete from insert into
      operation = $1.try(:upcase)

      case operation
      when "SELECT"
        summary = sql.split("FROM").first[0..100]
      when "INSERT"
        #sql.split(/VALUES/).first
        summary = sql.split("(").first[0..100]
      when "UPDATE", "INSERT"
        segment = sql.split(/WHERE/).first
        summary = segment.gsub!(/= *('[^\']*'|\$?[0-9.]*)/) { x = $1 ; x = ".{#{x.length}}" if x.length > 20 ; "= #{x.split("\n").first}"} || segment
      else # "DELETE|BEGIN|COMMIT|ROLLBACK
        summary = sql
      end
      if params
        #byebug
        summary += " "
        summary += fix_params(params).map(&:second).inspect
      end
      summary += " -- [#{size_sql(sql, params)}]" if include_count
      summary 
    end

    def size_sql(sql, params)
      sql.size + (params.nil? ? 0 : params.map { |param| param.last.inspect.size }.sum)
    end

    def fix_params(params)
      return unless params
      params.map do |param|
        val = case param.last
              when 'f'
                'false'
              when 't'
                'true'
              when nil
                'null'
              else
                param.last.to_s
              end
        if val.length > 20
          val = val[0..20] + "...[#{val.length}]"
        end
        [param.first, param.last]
      end
    end

    # loop through all children
    def all_nodes(node, skip_trivial = false, tgt = nil, &block)
      # TODO: remove from here - use prune instead (only used in print_node)
      return if skip_trivial && trivial(node)
      yield node, tgt
      node[:children].each { |c| all_nodes(c, skip_trivial, tgt, &block) } if node[:children]
      tgt
    end

    # take all sql calls from children, and merge into parent
    # TODO: only_same
    def merge_children(parent, target = parent)
      parent[:children].each do |child|
        target[:sql_timings] += child[:sql_timings]
        target[:sql_timings_duration_milliseconds] += child[:sql_timings_duration_milliseconds]
        target[:row_count] = target[:row_count].to_i + child[:row_count].to_i
        merge_children(child, target)
      end
      parent[:children] = []
    end

    # used by dedup_sql to merge multiple sql timer nodes
    def summarize_sql_nodes(snodes)
      summary = snodes.first
      summary[:count] = snodes.size
      summary[:duration_milliseconds] = snodes.map { |s| s[:duration_milliseconds] }.sum
      summary
    end

    def dedup_sql(snodes, aggressive = false)
      return snodes if snodes.nil? || snodes.size <= 1

      snodes.group_by { |snode | aggressive ? snode[:summary] : [snode[:formatted_command_string], snode[:parameters]] }.values
        .map do |dups|
          summarize_sql_nodes(dups)
        end
    end

    # string manipulation

    def avg(nodes, &block)
      nodes.blank? ? 0 : (nodes.map(&block).sum / nodes.length)
    end

    def f_to_s(f, tgt = 1)
      if f.kind_of?(Numeric)
        parts = f.round(tgt).to_s.split('.')
        parts[0].gsub!(/(\d)(?=(\d\d\d)+(?!\d))/, "\\1,")
        parts.join('.')
      else
        (f || "")
      end
    end

    def z_to_s(f, tgt = 1)
      f.kind_of?(Numeric) && f.round(tgt) == 0.0 ? nil : f_to_s(f, tgt)
    end
    # actual printing statements

    def fmt(spacer = ' ')
      durations = 1
      durations +=1 if display_children
      durations +=1 if display_offset

      "| " + (" %*s#{spacer}|" * durations) + # offset, duration, child duration
        "%5s#{spacer}| %*s#{spacer}| %8s#{spacer}|" + #sql count, sql duration, sql row count
        "#{spacer == ' ' ? "`" : " "}%s%s#{spacer == ' ' ? "`" : ""}" #pading, comment
    end

    @@padding = Hash.new { |hash, key| hash[key] = "." * key.to_i }
    def padded(count)
      @@padding[count]
    end

    def print_heading(depth, phrase)
      print_line(depth, nil, nil, nil, nil, nil, nil, phrase)
    end

    def print_line(depth, offset = nil,
                   duration, child_duration,
                   sql_count, sql_duration, sql_row_count, 
                   phrase)
      offset = f_to_s(offset)
      duration = f_to_s(duration)
      child_duration = f_to_s(child_duration)
      sql_duration = z_to_s(sql_duration)
      phrase = phrase.gsub("executing ","") if phrase
      sql_count = z_to_s(sql_count, 0)
      sql_row_count = z_to_s(sql_row_count, 0)

      data = []
      data += [width, offset] if display_offset
      data += [width, duration]
      data += [width, child_duration] if display_children
      data += [sql_count, width, sql_duration, sql_row_count] + [padded(depth)]
      data += [phrase]
      puts (offset == "---" ? fmt_h : fmt_d) % data
    end
  end
end