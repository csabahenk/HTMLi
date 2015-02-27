#!/usr/bin/env ruby

module HTMLi
extend self

  def tokenize doc
    tokens = []
    loop do
      i = doc.index /</m
      unless i
        tokens << [:str, doc] unless doc =~ /\A\s*\Z/m
        break
      end
      tokens << [:str, doc[0...i].sub(/\A\s+/m, " ").sub(/\s+\Z/m, " ")] unless doc[0...i] =~ /\A\s*\Z/m
      doc = doc[i..-1]
      fulltag, closing, tagname, attr, singleton = %r@\A<(/)?\s*(\w+)(?:\s+([^>]*[^>\s]))?\s*(/)?>@m.match(doc).to_a
      raise "#{fulltag.strip}: invalid tag" if (singleton or attr) and closing
      tokens << if closing
        [:tagclose, tagname]
      else
        [singleton ? :tagsingleton : :tagopen, tagname, attr]
      end
      doc = doc[fulltag.size..-1]
    end
    tokens
  end

  def sanitize tokens
    tstack = []
    voids = []
    tokens.each { |t|
      case t[0]
      when :str,:tagsingleton
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

  def mktree tokens
    tree = [[:root], []]
    cursor = [tree]
    tokens.each { |t|
      cat = t[0]
      cont = t[1..-1]
      if cat == :tagclose
        raise "tag mismatch: #{cursor[-1][0]} closed by #{t}" unless cursor[-1][0][1..1] == cont
        cursor.pop
      else
        cursor[-1][1] << case cat
        when :str
          t[1]
        when :tagsingleton, :tagvoid
          [[cat.to_s.sub(/^tag/,"").to_sym] + cont, []]
        when :tagopen
          cursor << [[:tag] + cont, []]
          cursor[-1]
        end
      end
    }
    raise "non-sanitized tokens" unless cursor == [tree]
    tree
  end

  def calc_height tree, intra=false
    return 0 if String === tree
    ha = []
    tree[1].each { |t|
      ha << calc_height(t, true)
    }
    tree[2] = (ha.max||0) + 1
    intra ? tree[2] : tree
  end

  def format tree, **opts
    opts = {out: $>, separator: "\n", indent: "  ", collapse: 2, level: 0, context:{}}.merge opts
    out,separator,collapse,context = opts.values_at(:out, :separator, :collapse, :context)
    indent = opts[:indent] * opts[:level]
    case tree
    when String
      tree.each_line { |l|
        out << indent if context[:lastchr] == separator
        out << l
        context[:lastchr] = l[-1]
      }
    when Array
      cat = tree[0][0]
      indenting = proc { out << indent if context[:lastchr] == separator }
      case cat
      when :root
        tree[1].each { |t| format t, **opts }
      when :void, :singleton
        indenting[]
        out << "<#{tree[0][1..-1].compact.join(" ")}#{cat == :singleton ? "/" : ""}>"
        context[:lastchr] = nil
      when :tag
        descending = proc { tree[1].each { |t| format t, **opts.merge(level: opts[:level]+1) } }
        if tree[2] and tree[2] <= collapse
          indenting[]
          out << "<#{tree[0][1..-1].compact.join(" ")}>"
          context[:lastchr] = nil
          descending[]
          indenting[]
          out << "</#{tree[0][1]}>"
          context[:lastchr] = nil
        else
          if context.key? :lastchr and context[:lastchr] != separator
            out << separator
            context[:lastchr] = separator
          end
          indenting[]
          out << "<#{tree[0][1..-1].compact.join(" ")}>" << separator
          descending[]
          unless context[:lastchr] == separator
            out << separator
            context[:lastchr] = separator
          end
          indenting[]
          out << "</#{tree[0][1]}>" << separator
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
  $*.each { |a|
    if a =~ /\A(?:--)?([^=:]+)[=:](.*)/
      opts[$1.to_sym] = begin
        Integer $2
      rescue ArgumentError
        $2
      end
    end
  }

  format calc_height(mktree(sanitize(tokenize(STDIN.read)))), **opts
end
