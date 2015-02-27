#!/usr/bin/env ruby

module HTMLi
extend self

  def tokenize doc
    tokens = []
    loop do
      i = doc.index /\s*</m
      unless i
        tokens << [:str, doc] unless doc.empty?
        break
      end
      tokens << [:str, doc[0...i]] unless i.zero?
      doc = doc[i..-1]
      fulltag, closing, tagname, attr, singleton = %r@\A\s*<(/)?\s*(\w+)(?:\s+([^>]*[^>\s]))?\s*(/)?>\s*@m.match(doc).to_a
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
    tree = [[:root]]
    cursor = [tree]
    tokens.each { |t|
      cat = t[0]
      cont = t[1..-1]
      if cat == :tagclose
        raise "tag mismatch: #{cursor[-1][0]} closed by #{t}" unless cursor[-1][0][1..1] == cont
        cursor.pop
      else
        cursor[-1] << case cat
        when :str
          t[1]
        when :tagsingleton, :tagvoid
          [[cat.to_s.sub(/^tag/,"").to_sym] + cont]
        when :tagopen
          cursor << [[:tag] + cont]
          cursor[-1]
        end
      end
    }
    raise "non-sanitized tokens" unless cursor == [tree]
    tree
  end

  def format tree, **opts
    opts = {out: $>, separator: "\n", indent: "  ", level: 0, context:{}}.merge opts
    out,separator,context = opts.values_at(:out, :separator, :context)
    indent = opts[:indent] * opts[:level]
    case tree
    when String
      out << " " if %i[void singleton tag].include? context[:lasttype] and context[:lastchr] != separator
      tree.each_line { |l|
        out << indent if context[:lastchr] == separator
        out << l
        context[:lastchr] = l[-1]
      }
      context[:lasttype] = String
    when Array
      cat = tree[0][0]
      case cat
      when :root
        tree[1..-1].each { |t| format t, **opts }
      when :void, :singleton
        out << if context[:lastchr] == separator
          indent
        elsif context[:lasttype] == String and context[:lastchr] !~ /\s/
          " "
        else
          ""
        end
        out << "<#{tree[0][1..-1].compact.join(" ")}#{cat == :singleton ? "/" : ""}>"
        context[:lastchr] = nil
      when :tag
        if context.key? :lastchr and context[:lastchr] != separator
          out << separator
        end
        out << indent << "<#{tree[0][1..-1].compact.join(" ")}>" << separator
        context.merge! lastchr: separator, lasttype: cat
        tree[1..-1].each { |t| format t, **opts.merge(level: opts[:level]+1) }
        out << separator unless context[:lastchr] == separator
        out << indent << "</#{tree[0][1]}>" << separator
        context[:lastchr] = separator
      else
        raise "unknown token category #{cat}"
      end
      context[:lasttype] = cat
    end
    out
  end

end


if __FILE__ == $0
  include HTMLi

  opts = {}
  $*.each { |a|
    if a =~ /\A(?:--)?([^=:]+)[=:](.*)/
     opts[$1.to_sym] = $2
    end
  }

  format mktree(sanitize(tokenize(STDIN.read))), **opts
end
