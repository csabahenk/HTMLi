require 'optparse'


class SimpleOpts

  class Opt

    def self.classfixer c
      case c.name
      when "Fixnum"
        Integer
      when "FalseClass"
        TrueClass
      else
        c
      end
    end

    def self.represent v
      case v
      when ""
        '""'
      when String
        w = v.inspect
        [v, w[1...-1], v.strip].uniq.size == 1 ? v : w
      when Regexp
        v.inspect
      when Class
        "(required)"
      else
        v.to_s
      end
    end

    private def setup
      @type = self.class.classfixer(@type ||
                (@default == :auto ? String : @default.class))
      @default_rep ||= self.class.represent(default)
    end

    def initialize name: nil, type: nil, default: :auto, default_rep: nil,
                   short: :auto, argument: :auto, info: "%{default}"
      @name = name
      @default = default
      @default_rep = default_rep
      @type = type
      @info = info
      @short = short
      @argument = argument
      setup
    end

    attr_accessor :name, :type, :info, :default_rep
    attr_writer :default, :short, :argument

    def default
      @default == :auto ? type : @default
    end

    def argument
      @argument == :auto or return @argument

      # Classes don't match themselves with === operator,
      # so the case construct has to dispatch on their names.
      # Also some of the classes we are to dispatch on may
      # not be defined (Date*) -- thus dispatching on the name
      # avoids reference to an undefined.
      case type.name
      when 'Integer','Float'
        "N"
      when 'TrueClass','FalseClass'
        "[BOOL]"
      when 'Array'
        "VAL,.."
      when 'Regexp'
        "PAT"
      when 'Date','Time','DateTime'
        "T"
      else
        "VAL"
      end
    end

    def short
      case @short
      when :auto, true
        @name[0]
      when nil, false
        nil
      else
        @short
      end
    end

    def short_set?
      @short != :auto
    end

  end

  attr_reader :optionparser
  alias op optionparser

  def initialize optionparser: nil, help_args: nil
    @optionparser = optionparser || OptionParser.new
    help_args and op.banner << " " << help_args
    @opts = {}
    @shortopts = []
  end

  def add_opts inopts, optclass: Opt
    opts = inopts.map do |o,d|
      optname = o.to_s.gsub "_", "-"
      opt = case d
      when Opt,optclass
        d.name ||= optname
        d
      when Class
        optclass.new name: optname, type: d
      else
        optclass.new name: optname, default: d
      end
      [o, {opt: opt, default: opt.default}]
    end.to_h

    opts.each { |o,w|
      # Mangling opts to OptionParser options in a graceful manner
      # - opt_name: <scalar> becomes:
      #   op.on("-o", "--opt-name", fixer[<scalar>.class], <scalar>.to_s) {...}
      # - opt_name: <class> becomes: op.on("-o", "--opt-name", fixer[<class>]) {...}
      #   where fixer is needed to map arbitrary classes into the class set
      #   accepted by OptionParser
      # This is actually the special case of the following general mechanism
      # (through making an Opt instance <opt> from given <scalar>/<class>):
      # - opt_name: <opt> becomes:
      #   op.on("-"+<opt>.short, "--" + <opt>.name, <opt>.type,
      #         <opt>.info % <opt>.default) {...}
      opt = w[:opt]
      if @shortopts.include? opt.short
        opt.short_set? or opt.short = nil
      else
        @shortopts << opt.short
      end
      optargs = [
        opt.short ? "-" + opt.short : nil,
        ["--" + opt.name, opt.argument].compact.join("="),
        opt.type,
        opt.info % {default: opt.default_rep}
      ].compact
      @optionparser.on(*optargs) { |v| opts[o][:cmdline] = v }
    }

    @opts.merge! opts
    nil
  end

  private def supress_unshortopts
    unshortopts = @opts.map { |o,w| w[:opt].name[0] } - @shortopts
    unshortopts.each { |o|
      o == ?h and next
      sw = @optionparser.make_switch([?-+o], proc { raise OptionParser::InvalidOption, ?-+o })[0]
      class << sw
        def summarize *x
        end
      end
      @optionparser.top.append sw
    }
    if unshortopts.include? ?h
      @optionparser.instance_variable_get(:@stack).then {|s|
        s << s.find {|l| l.long.key? "help" }
      }
    end
  end

  def parse argv
    @optionparser.parse! argv
  end

  def conf conf_opt, keep_conf_opt: false
    conf_resource = (@opts[conf_opt]||{}).values_at(
       :cmdline, :default).compact.first
    keep_conf_opt or @opts.delete(conf_opt)
    if conf_resource
       conf_load(conf_resource).each { |k,v|
        (@opts[k.to_sym]||{})[:conf] = v
      }
    end
    nil
  end

  def emit
    opts = {}
    @opts.each { |o,w|
      k = %i[cmdline conf default].find { |k| w.key? k }
      v = w[k]
      Class === v and missing(w[:opt].name)
      opts[o] = v
    }
    opts
  end

  def self.get inopts, argv: $*, conf_opt: nil, keep_conf_opt: false,
      optclass: Opt, help_args: nil
    simpleopts = new(help_args: help_args)
    [inopts].flatten.each { |oh| simpleopts.add_opts(oh, optclass: optclass) }
    simpleopts.send :supress_unshortopts
    simpleopts.parse argv
    conf_opt and simpleopts.conf(conf_opt, keep_conf_opt: keep_conf_opt)
    simpleopts.emit
  end

  def missing optname
    puts "missing value for --#{optname}"
    exit 1
  end

  def conf_load resource
    YAML.load_file resource
  end

end
