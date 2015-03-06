#!/usr/bin/env ruby


module HTMLi
extend self

  def pretokenize src
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
        yield cat, tok unless tok =~ /\A\s*\Z/m
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
        when "!"
          [:declaration, tok[2..-2]]
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
    tokens.each { |t|
      case t[0]
      when :str,:tagsingleton,:comment,:declaration
      when :tagopen
        tstack << t
      when :tagclose
        while to = tstack.pop
          break if to[1] == t[1]
          voids << to
        end
        raise "missing opening for #{t[1]}" unless to
      else
        raise "unknown token category #{t[0]}"
      end
    }
    voids.concat tstack
    voids.each { |t| t[0] = :tagvoid }
    tokens
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

  class StandardLayout < LayoutBase

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
            # of StandardLayout or a tree that's part of inlined
            # container of InlineLayout.
            when nil,String,Integer
              # b can't be tree, as trees start with an Array,
              # so by exclusion we reach to StandardLayout
              StandardLayout
            when Array
              # were b a tree, it's starting element's starting
              # element should be a symbol/string; in the other
              # case that's still an array
              Array === b[0][0] ? StandardLayout : InlineLayout
            else
              raise "invalid tree #{tree}"
            end
          end
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
    _LO = findlayout layout: (layout||StandardLayout)
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
        when :tagsingleton, :tagvoid, :declaration, :comment
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

  def tag_height tree, layout: nil
    unless tree.respond_to? :height=
      class << tree
        attr_accessor :height
      end
    end
    tree.height = case tree
    when String
      0
    when Array
      (findlayout(tree, layout: layout).content.map { |t|
         tag_height(t, layout: layout)
         t.height
       }.max || 0) + 1
    else
      raise "invalid tree #{tree}"
    end
    tree
  end

  def format tree, **opts
    opts = {out: $>, separator: "\n", indent: "  ", collapse: 2, layout: nil, level: 0, context:{}}.merge opts
    out,separator,collapse,layout,context = opts.values_at(:out, :separator, :collapse, :layout, :context)
    indent = opts[:indent] * opts[:level]
    case tree
    when String
      tree.each_line { |l|
        out << indent if context[:lastchr] == separator
        out << l
        context[:lastchr] = l[-1]
      }
    when Array
      tree = findlayout tree, layout: layout
      cat = tree.category
      indenting = proc { out << indent if context[:lastchr] == separator }
      case cat.to_s
      when "root"
        tree.content.each { |t| format t, **opts }
      when "void", "singleton"
        indenting[]
        out << "<#{[tree.tag, tree.attr].compact.join(" ")}#{cat == :singleton ? "/" : ""}>"
        context[:lastchr] = nil
      when "declaration", "comment"
        marker = cat.to_s == "comment" ? "--" : ""
        indenting[]
        out << "<!#{marker}#{tree.tag}#{marker}>" << separator
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
        if height and height <= collapse
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
        raise "unknown token category #{cat}"
      end
    end
    out
  end

end


if __FILE__ == $0
  include HTMLi

  opts = {}
  args = []
  while a = $*.shift
    if a == "--"
      break
    elsif a =~ /\A(?:--)?([^=:]+)[=:](.*)/
      o,v = $1,$2
      opts[o.to_sym] = case v
      when /\A\d+\Z/
        Integer v
      else
        v
      end
    else
      args << a
    end
  end

  $*.insert(0, args).flatten!

  layout = opts.delete :layout
  from = opts.delete :from
  tree = case from
  when "html", nil
    mktree sanitize(tokenize($<)), layout: layout
  when "json"
    require 'json'
    JSON.load $<
  else
    raise "unknown input format #{from}"
  end

  case opts.delete :format
  when "json"
    require 'json'
    puts tree.to_json
  when "yaml"
    require 'yaml'
    puts tree.to_yaml
  when %r{\A(json[:-_#@/.])?yajl\Z}
    require 'yajl'
    Yajl::Encoder.encode tree, $>
  when "html", nil
    format tag_height(tree), **opts
  else
    raise "unknown format #{format}"
  end
end
