#!/usr/bin/env ruby

begin
  Hash.instance_method :compact
rescue NameError
  require 'polyfill'

  using Polyfill(
    Hash: %w[#compact]
  )
end

module HTMLi
extend self

  def pretokenize src
    unless block_given?
      return to_enum(:pretokenize, src)
    end

    tok = ""
    cat = :str
    eci = src.instance_eval { respond_to?(:each_char) ? each_char : each }
    loop do
      begin
        c = eci.next
        if c == "<" and cat == :str
          yield cat, tok unless tok =~ /\A\s*\Z/m
          tok = c
          cat = :tag
          %w[! - -].each { |q|
            tok << eci.next
            break unless tok[-1] == q
          }
          if tok[-3..-1] == "!--"
            cat = :comment
          elsif tok[-1] == ">"
            yield cat, tok
            tok = ""
            cat = :str
          end
        else
          tok << c
          if (cat == :tag and tok[-1] == ">") or
             # XXX with this, truncated comments like
             # <!---> are also considered to be comments
             # but <!-- -- > is missed out
             (cat == :comment and tok[-3..-1] == "-->")
            yield cat, tok
            tok = ""
            cat = :str
          end
        end
      rescue StopIteration
        yield :str, tok unless tok =~ /\A\s*\Z/m
        break
      end
    end
  end

  def tokenize src
    tokens = []
    pretokenize(src) { |cat, tok|
      tokens << case cat
      when :str
        [cat, tok.sub(/\A\s+/m, " ").sub(/\s+\Z/m, " ")]
      when :comment
        [cat, tok[4..-4]]
      when :tag
        case tok[1]
        when "/"
          [:tagclose, tok[2...-1].strip]
        else
          cat,i = tok[-2] == "/" ? [:tagsingleton, -2] : [:tagopen, -1]
          tag, attr = tok[1...i].split(/\s+/m, 2).map(&:strip)
          [cat, tag] + [attr].compact
        end
      end
    }
    tokens
  end

  def sanitize tokens
    tstack = []
    voids = []
    orphans = []
    tokens.each { |t|
      case t[0]
      when :str,:tagsingleton,:comment
      when :tagopen
        tstack << t
      when :tagclose
        while to = tstack.pop
          break if to[1] == t[1]
          voids << to
        end
        orphans << t unless to
      else
        raise "unknown token category #{t[0]}"
      end
    }
    voids.concat tstack
    voids.each { |t| t[0] = :tagvoid }
    orphans.each { |t| t[0] = :tagorphan }
    tokens
  end

  ORPHAN_STRATEGIES = {
    allow: proc { |t| t },
    ignore: proc { },
    raise: proc { |t| raise "missing opening for #{t[1]}" },
    warn: proc { |t| STDERR.puts "warning: missing opening for #{t[1]}"; t },
  }

  def filter_orphans tokens, strategy
    strategy ||= :raise
    strategy_cbk = ORPHAN_STRATEGIES[strategy.to_sym]
    strategy_cbk or  raise "unkown orphan strategy #{strategy.inspect}"
    tokens.map { |t| t[0] == :tagorphan ? strategy_cbk[t] : t }.compact
  end

  class LayoutBase

    attr_reader :tree

    def category
      tree[0][0]
    end

    def tag
      tree[0][1]
    end

    def attr
      tree[0][2]
    end

    def self.makehead cat, tag, attr=nil
      [cat, tag] + [attr].compact
    end

  end

  class NestedLayout < LayoutBase

    def initialize category, tag, attr:nil, content:[]
      @tree = [self.class.makehead(category, tag, attr), content]
    end

    def content
      tree[1]
    end

    def << e
      content << e
    end

  end

  class InlineLayout < LayoutBase

    def initialize category, tag, attr:nil, content:[]
      @tree = [self.class.makehead(category, tag, attr)] + content
    end

    def content
      tree[1..-1].select { |e| [Array, String].include? e.class }
    end

    def << e
      tree << e
    end

  end

  class MapLayout < LayoutBase

    NOTag = ""

    def initialize category, tag, attr:nil, content:[]
      @tree = self.class.makehead(category, tag, attr)
      @tree[tag||NOTag].concat content
    end

    def category
      tree["typ"]
    end

    def tag
      t = (tree.keys - %w[typ attr]).first
      t == NOTag ? nil : t
    end

    def attr
      tree["attr"]
    end

    def self.makehead cat, tag, attr=nil
      {"typ"=> cat, "attr"=> attr, (tag||NOTag)=>[]}.compact
    end

    def content
      tree[tag||NOTag]
    end

    def << e
      content << e
    end

  end

  def findlayout tree=nil, layout: nil
    layoutcls = case layout
    when String, Symbol
      HTMLi.const_get(layout.to_s.capitalize + "Layout")
    when Class
      layout
    when nil
      if LayoutBase === tree
        tree.class
      else
        case tree
        when Hash
          MapLayout
        when Array
          case tree.size
          when 0
            raise "invalid tree #{tree}"
          when 1
            InlineLayout
          else
            b = tree[1]
            case b
            when String,Integer
              InlineLayout
            when Array
              case b[0]
              # if b is Array, it's either the content container
              # of NestedLayout or a tree that's part of inlined
              # container of InlineLayout.
              when nil,String,Integer
                # b can't be tree, as trees start with an Array,
                # so by exclusion we reach to NestedLayout
                NestedLayout
              when Array
                # were b a tree, it's starting element's starting
                # element should be a symbol/string; in the other
                # case that's still an array
                Array === b[0][0] ? NestedLayout : InlineLayout
              else
                raise "invalid tree #{tree}"
              end
            end
          end
        else
          raise "invalid tree type #{tree.class}"
        end
      end
    else
      raise "unknown layout representation #{layout.class}"
    end
    if tree
      if LayoutBase === tree
        raise TypeError, "tree (#{tree.class}) does not match layout #{layout}" unless tree.class == layoutcls
        return tree
      end
      layoutcls.allocate.instance_eval {
        @tree = tree
        self
      }
    else
      layoutcls
    end
  end

  def mktree tokens, layout:nil
    _LO = findlayout layout: (layout||MapLayout)
    tree = _LO.new :root, nil
    cursor = [tree]
    tokens.each { |t|
      cat = t[0]
      payload = t[1..-1]
      if cat == :tagclose
        raise "tag mismatch: #{cursor[-1].tag} closed by #{t}" unless payload == [cursor[-1].tag]
        cursor.pop
      else
        cursor[-1] << case cat
        when :str
          payload[0]
        when :tagsingleton, :tagvoid, :tagorphan, :comment
          _LO.new(cat.to_s.sub(/^tag/,"").to_sym, payload[0], attr: payload[1]).tree
        when :tagopen
          cursor << _LO.new(:tag, payload[0], attr: payload[1])
          cursor[-1].tree
        end
      end
    }
    raise "non-sanitized tokens" unless cursor == [tree]
    tree.tree
  end

  def parse src, **opts
    mktree(filter_orphans(sanitize(tokenize src),
                          opts.delete(:orphan_strategy)),
           **opts)
  end

  def _flatten_iter tree, out, layout: nil
    case tree
    when String
      out << [:str, tree]
    when Array
      tree = findlayout tree, layout: layout
      cat = tree.category.to_s
      unless cat == "root"
        out << [
         case cat
         when "tag"
           :tagopen
         when "void", "singleton", "orphan"
           ("tag" + cat).to_sym
         when "comment"
           :comment
         else
           raise "unknown token category #{cat}"
         end,
         tree.tag] + [tree.attr].compact
      end
      if %w[root tag].include? cat
        tree.content.each { |t| _flatten_iter t, out, layout: layout }
      end
      if cat == "tag"
        out << [:tagclose, tree.tag]
      end
    end
    out
  end

  def flatten tree, layout: nil
    Enumerator.new do |y|
      _flatten_iter tree, y, layout: layout
    end
  end

  def tag_height tree, layout: nil
    unless tree.respond_to? :height=
      class << tree
        attr_accessor :height
      end
    end
    tree.height = case tree
    when String
      0
    when Array,Hash
      (findlayout(tree, layout: layout).content.map { |t|
         tag_height(t, layout: layout)
         t.height
       }.max || 0) + 1
    else
      raise "invalid tree #{tree}"
    end
    tree
  end

  FORMAT_OPTS = {separator: "\n", indent: "  ", collapse: nil, layout: nil}

  def format tree, **opts
    opts = {out: $>, level: 0, context:{}}.merge(FORMAT_OPTS).merge opts
    out,separator,collapse,layout,context = opts.values_at(:out, :separator, :collapse, :layout, :context)
    indent = opts[:indent] * opts[:level]
    if collapse and !tree.respond_to? :height
      tree = tag_height(tree)
    end
    case tree
    when String
      tree.each_line { |l|
        out << indent if context[:lastchr] == separator
        out << l
        context[:lastchr] = l[-1]
      }
    when Array,Hash
      tree = findlayout tree, layout: layout
      cat = tree.category
      indenting = proc { out << indent if context[:lastchr] == separator }
      case cat.to_s
      when "root"
        tree.content.each { |t| format t, **opts }
      when "void", "singleton"
        indenting[]
        out << "<#{[tree.tag, tree.attr].compact.join(" ")}#{cat.to_s == "singleton" ? "/" : ""}>"
        context[:lastchr] = nil
      when "orphan"
        indenting[]
        out << "</#{[tree.tag, tree.attr].compact.join(" ")}>"
        context[:lastchr] = nil
      when "comment"
        indenting[]
        out << "<!--#{tree.tag}-->" << separator
        context[:lastchr] = separator
      when "tag"
        descending = proc { tree.content.each { |t| format t, **opts.merge(level: opts[:level]+1) } }
        height = nil
        [tree, tree.tree].each { |t|
          if t.respond_to? :height
            height = t.height
            break
          end
        }
        if collapse and height and height <= collapse
          indenting[]
          out << "<#{[tree.tag, tree.attr].compact.join(" ")}>"
          context[:lastchr] = nil
          descending[]
          indenting[]
          out << "</#{tree.tag}>"
          context[:lastchr] = nil
        else
          if context.key? :lastchr and context[:lastchr] != separator
            out << separator
            context[:lastchr] = separator
          end
          indenting[]
          out << "<#{[tree.tag, tree.attr].compact.join(" ")}>" << separator
          context[:lastchr] = separator
          descending[]
          unless context[:lastchr] == separator
            out << separator
            context[:lastchr] = separator
          end
          indenting[]
          out << "</#{tree.tag}>" << separator
        end
      else
        raise "unknown token category #{cat.inspect}"
      end
    end
    out
  end

end


if __FILE__ == $0
  require_relative 'simpleopts'
  include HTMLi

  dispatch = {
    from: {
      "html" => proc { |opts| parse $<, **opts },
      "json" => proc { |opts|
        require 'json'
        JSON.load $<
      },
      "yaml" => proc { |opts|
        require 'yaml'
        YAML.load $<
      },
      "json/yajl" => proc { |opts|
        require 'yajl'
        $*.size <= 1 or raise "Yajl does not support muliple input files"
        ($*.empty? ?
         proc { |&b| b[STDIN] } :
         proc { |&b| open($*.first, &b) }).call { |f| Yajl::Parser.parse f }
      }
    },
    to: {
      "json" => proc { |tree,opts|
        require 'json'
        puts tree.to_json
      },
      "yaml" => proc { |tree,opts|
        require 'yaml'
        puts tree.to_yaml
      },
      "json/yajl" => proc { |tree,opts|
        require 'yajl'
        Yajl::Encoder.encode tree, $>
      },
      "html" => proc { |tree,opts| format tree, **opts },
    }
  }

  Opt = SimpleOpts::Opt
  mkchoices = proc { |key| dispatch[key].keys.sort.join "," }
  opttable = {
    to_opts: FORMAT_OPTS.compact.merge(collapse: 2),
    from_opts: {
      layout: Opt.new(
        default: 'map',
        info: "%{default} (of #{HTMLi.constants.grep(/Layout\Z/).map {|c| c.to_s.sub(/Layout\Z/, "").downcase }.join ","})"
      ),
      orphan_strategy: Opt.new(
        default: "raise",
        info: "%{default} (of #{ORPHAN_STRATEGIES.keys.join(?,)})"
      ),
    },
    dispatch_opts: dispatch.keys.map { |key|
      [key,
      Opt.new(default: "html", info: "%{default} (of #{mkchoices[key]})")]
    }.to_h
  }

  opts = SimpleOpts.get(opttable.values, help_args: "[ < ] file,..")
  optvalues = opttable.transform_values { |h| opts.select { |k| h.key? k }}

  cbks = dispatch.map { |key,table| [key, table[optvalues[:dispatch_opts][key]]] }.to_h
  cbks.each do |key,cbk|
    cbk or  raise "--#{key}: should be one of #{mkchoices[key]}"
  end

  cbks[:to].call cbks[:from].call(optvalues[:from_opts]), optvalues[:to_opts]
end
