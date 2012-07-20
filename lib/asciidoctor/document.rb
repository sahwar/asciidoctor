# Public: Methods for parsing Asciidoc documents and rendering them
# using erb templates.
class Asciidoctor::Document

  include Asciidoctor

  # Public: Get the String document source.
  attr_reader :source

  # Public: Get the Asciidoctor::Renderer instance currently being used
  # to render this Document.
  attr_reader :renderer

  # Public: Get the Hash of defines
  attr_reader :defines

  # Public: Get the Hash of document references
  attr_reader :references

  # Need these for pseudo-template yum
  attr_reader :header, :preamble

  # Public: Get the Array of elements (really Blocks or Sections) for the document
  attr_reader :elements

  # Public: Convert a string to a legal attribute name.
  #
  # name  - The String holding the Asciidoc attribute name.
  #
  # Returns a String with the legal name.
  #
  # Examples
  #
  #   sanitize_attribute_name('Foo Bar')
  #   => 'foobar'
  #
  #   sanitize_attribute_name('foo')
  #   => 'foo'
  #
  #   sanitize_attribute_name('Foo 3 #-Billy')
  #   => 'foo3-billy'
  def sanitize_attribute_name(name)
    name.gsub(/[^\w\-_]/, '').downcase
  end

  # Public: Initialize an Asciidoc object.
  #
  # data  - The Array of Strings holding the Asciidoc source document.
  # block - A block that can be used to retrieve external Asciidoc
  #         data to include in this document.
  #
  # Examples
  #
  #   data = File.readlines(filename)
  #   doc  = Asciidoctor::Document.new(data)
  def initialize(data, &block)
    raw_source = []
    @elements = []
    @defines = {}
    @references = {}

    include_regexp = /^include::([^\[]+)\[\]\s*\n?\z/

    data.each do |line|
      if inc = line.match(include_regexp)
        raw_source.concat(File.readlines(inc[1]))
      else
        raw_source << line
      end
    end

    ifdef_regexp = /^(ifdef|ifndef)::([^\[]+)\[\]/
    endif_regexp = /^endif::/
    defattr_regexp = /^:([^:]+):\s*(.*)\s*$/
    conditional_regexp = /^\s*\{([^\?]+)\?\s*([^\}]+)\s*\}/

    skip_to = nil
    continuing_value = nil
    continuing_key = nil
    @lines = []
    raw_source.each do |line|
      if skip_to
        skip_to = nil if line.match(skip_to)
      elsif continuing_value
        close_continue = false
        # Lines that start with whitespace and end with a '+' are
        # a continuation, so gobble them up into `value`
        if match = line.match(/\s+(.+)\s+\+\s*$/)
          continuing_value += match[1]
        elsif match = line.match(/\s+(.+)/)
          # If this continued line doesn't end with a +, then this
          # is the end of the continuation, no matter what the next
          # line does.
          continuing_value += match[1]
          close_continue = true
        else
          # If this line doesn't start with whitespace, then it's
          # not a valid continuation line, so push it back for processing
          close_continue = true
          raw_source.unshift(line)
        end
        if close_continue
          @defines[continuing_key] = continuing_value
          continuing_key = nil
          continuing_value = nil
        end
      elsif match = line.match(ifdef_regexp)
        attr = match[2]
        skip = case match[1]
               when 'ifdef';  !@defines.has_key?(attr)
               when 'ifndef'; @defines.has_key?(attr)
               end
        skip_to = /^endif::#{attr}\[\]\s*\n/ if skip
      elsif match = line.match(defattr_regexp)
        key = sanitize_attribute_name(match[1])
        value = match[2]
        if match = value.match(Asciidoctor::REGEXP[:attr_continue])
          # attribute value continuation line; grab lines until we run out
          # of continuation lines
          continuing_key = key
          continuing_value = match[1]  # strip off the spaces and +
          Asciidoctor.debug "continuing key: #{continuing_key} with partial value: '#{continuing_value}'"
        else
          @defines[key] = value
          Asciidoctor.debug "Defines[#{key}] is '#{value}'"
        end
      elsif !line.match(endif_regexp)
        while match = line.match(conditional_regexp)
          value = @defines.has_key?(match[1]) ? match[2] : ''
          line.sub!(conditional_regexp, value)
        end
        @lines << line unless line.match(REGEXP[:comment])
      end
    end

    # Process bibliography references, so they're available when text
    # before the reference is being rendered.
    @lines.each do |line|
      if biblio = line.match(REGEXP[:biblio])
        references[biblio[1]] = "[#{biblio[1]}]"
      end
    end

    @source = @lines.join

    # Now parse @lines into elements
    while @lines.any?
      skip_blank(@lines)

      @elements << next_block(@lines) if @lines.any?
    end

    Asciidoctor.debug "Found #{@elements.size} elements in this document:"
    @elements.each do |el|
      Asciidoctor.debug el
    end

    root = @elements.first
    # Try to find a @header from the Section blocks we have (if any).
    if root.is_a?(Section) && root.level == 0
      @header = @elements.shift
      @elements = @header.blocks + @elements
      @header.clear_blocks
    end

  end

  # We need to be able to return some semblance of a title
  def title
    return @title if @title

    if @header
      @title = @header.title || @header.name
    elsif @elements.first
      @title = @elements.first.title
      # Blocks don't have a :name method, but Sections do
      @title ||= @elements.first.name if @elements.first.respond_to? :name
    end

    @title
  end

  def splain
    if @header
      puts "Header is #{@header}"
    else
      puts "No header"
    end

    puts "I have #{@elements.count} elements"
    @elements.each_with_index do |block, i|
      puts "v" * 60
      puts "Block ##{i} is a #{block.class}"
      puts "Name is #{block.name rescue 'n/a'}"
      block.splain(0) if block.respond_to? :splain
      puts "^" * 60
    end
    nil
  end

  # Public: Render the Asciidoc document using erb templates
  #
  def render
    @renderer ||= Renderer.new
    html = self.renderer.render('document', self, :header => @header, :preamble => @preamble)
  end

  def content
    html_pieces = []
    @elements.each do |element|
      Asciidoctor::debug "Rendering element: #{element}"
      html_pieces << element.render
    end
    html_pieces.join("\n")
  end

  private

  # Private: Strip off leading blank lines in the Array of lines.
  #
  # lines - the Array of String lines.
  #
  # Returns nil.
  #
  # Examples
  #
  #   content
  #   => ["\n", "\t\n", "Foo\n", "Bar\n", "\n"]
  #
  #   skip_blank(content)
  #   => nil
  #
  #   lines
  #   => ["Foo\n", "Bar\n"]
  def skip_blank(lines)
    while lines.any? && lines.first.strip.empty?
      lines.shift
    end

    nil
  end

  # Private: Return all the lines from `lines` until we (1) run out them,
  #   (2) find a blank line with :break_on_blank_lines => true, or (3) find
  #   a line for which the given block evals to true.
  #
  # lines   - the Array of Strings to process
  # options - an optional Hash of processing options:
  #           * :break_on_blank_lines may be used to specify to break on
  #               blank lines
  #           * :preserve_last_line may be used to specify that the String
  #               causing the method to stop processing lines should be
  #               pushed back onto the `lines` Array.
  #
  # Returns the Array of lines forming the next segment.
  #
  # Examples
  #
  #   content
  #   => ["First paragraph\n", "Second paragraph\n", "Open block\n", "\n",
  #       "Can have blank lines\n", "--\n", "\n", "In a different segment\n"]
  #
  #   grab_lines_until(content)
  #   => ["First paragraph\n", "Second paragraph\n", "Open block\n"]
  #
  #   content
  #   => ["In a different segment\n"]
  def grab_lines_until(lines, options = {}, &block)
    buffer = []

    while (this_line = lines.shift)
      Asciidoctor.debug "Processing line: '#{this_line}'"
      finis ||= true if options[:break_on_blank_lines] && this_line.strip.empty?
      finis ||= true if block && value = yield(this_line)
      if finis
        lines.unshift(this_line) if options[:preserve_last_line]
        break
      end

      buffer << this_line
    end
    buffer
  end

  # Private: Return the Array of lines constituting the next list item
  #          segment, removing them from the 'lines' Array passed in.
  #
  # lines   - the Array of String lines.
  # options - an optional Hash of processing options:
  #           * :alt_ending may be used to specify a regular expression match
  #             other than a blank line to signify the end of the segment.
  #           * :list_types may be used to specify list item patterns to
  #             include. May be either a single Symbol or an Array of Symbols.
  #           * :list_level may be used to specify a mimimum list item level
  #             to include. If this is specified, then break if we find a list
  #             item of a lower level.
  #
  # Returns the Array of lines forming the next segment.
  #
  # Examples
  #
  #   content
  #   => ["First paragraph\n", "+\n", "Second paragraph\n", "--\n",
  #       "Open block\n", "\n", "Can have blank lines\n", "--\n", "\n",
  #       "In a different segment\n"]
  #
  #   list_item_segment(content)
  #   => ["First paragraph\n", "+\n", "Second paragraph\n", "--\n",
  #       "Open block\n", "\n", "Can have blank lines\n", "--\n"]
  #
  #   content
  #   => ["In a different segment\n"]
  def list_item_segment(lines, options={})
    alternate_ending = options[:alt_ending]
    list_types = Array(options[:list_types]) || [:ulist, :olist, :colist, :dlist]
    list_level = options[:list_level].to_i

    # We know we want to include :lit_par types, even if we have specified,
    # say, only :ulist type list entries.
    list_types << :lit_par unless list_types.include? :lit_par
    segment = []

    skip_blank(lines)

    # Grab lines until the first blank line not inside an open block
    # or listing
    in_oblock = false
    in_listing = false
    while lines.any?
      this_line = lines.shift
      puts "----->  Processing: #{this_line}"
      in_oblock = !in_oblock if this_line.match(REGEXP[:oblock])
      in_listing = !in_listing if this_line.match(REGEXP[:listing])
      if !in_oblock && !in_listing
        if this_line.strip.empty?
          next_nonblank = lines.detect{|l| !l.strip.empty?}

          # If there are blank lines ahead, but there's at least one
          # more non-blank line that doesn't trigger an alternate_ending
          # for the block of lines, then vacuum up all the blank lines
          # into this segment and continue with the next non-blank line.
          if next_nonblank &&
             ( alternate_ending.nil? ||
               !next_nonblank.match(alternate_ending)
             ) && list_types.find { |list_type| next_nonblank.match(REGEXP[list_type]) }

             while lines.first.strip.empty?
               segment << this_line
               this_line = lines.shift
             end
          else
            break
          end

        # Have we come to a line matching an alternate_ending regexp?
        elsif alternate_ending && this_line.match(alternate_ending)
          lines.unshift this_line
          break

        # Do we have a minimum list_level, and have come to a list item
        # line with a lower level?
        elsif list_level &&
              list_types.find { |list_type| this_line.match(REGEXP[list_type]) } &&
              ($1.length < list_level)
          lines.unshift this_line
          break
        end

        # From the Asciidoc user's guide:
        #   Another list or a literal paragraph immediately following
        #   a list item will be implicitly included in the list item

        # Thus, the list_level stuff may be wrong here.
      end

      segment << this_line
    end

    puts "*"*40
    puts "#{File.basename(__FILE__)}:#{__LINE__} -> #{__method__}: Returning this:"
    puts segment.inspect
    puts "*"*10
    puts "Leaving #{__method__}: Top of lines queue is:"
    puts lines.first
    puts "*"*40
    segment
  end

  def build_ulist_item(lines, block, match = nil)
    list_type = :ulist
    this_line = lines.shift
    return nil unless this_line

    match ||= this_line.match(REGEXP[list_type])
    if match.nil?
      lines.unshift(this_line)
      return nil
    end

    level = match[1].length

    list_item = ListItem.new
    list_item.level = level
    puts "#{__FILE__}:#{__LINE__}: Created ListItem #{list_item} with match[2]: #{match[2]} and level: #{list_item.level}"

    # Prevent bullet list text starting with . from being treated as a paragraph
    # title or some other unseemly thing in list_item_segment. I think. (NOTE)
    lines.unshift match[2].lstrip.sub(/^\./, '\.')

    item_segment = list_item_segment(lines, :alt_ending => REGEXP[list_type])
#    item_segment = list_item_segment(lines)
    while item_segment.any?
      list_item.blocks << next_block(item_segment, block)
    end

    puts "\n\nlist_item has #{list_item.blocks.count} blocks, and first is a #{list_item.blocks.first.class} with context #{list_item.blocks.first.context rescue 'n/a'}\n\n"

    first_block = list_item.blocks.first
    if first_block.is_a?(Block) &&
       (first_block.context == :paragraph || first_block.context == :literal)
      list_item.content = first_block.buffer.map{|l| l.strip}.join("\n")
      list_item.blocks.shift
    end

    list_item
  end

  def build_ulist(lines, parent = nil)
    items = []
    list_type = :ulist
    block = Block.new(parent, list_type)
    puts "Created :ulist block: #{block}"
    first_item_level = nil

    while lines.any? && match = lines.first.match(REGEXP[list_type])

      this_item_level = match[1].length

      if first_item_level && first_item_level < this_item_level
        # If this next :uline level is down one from the
        # current Block's, put it in a Block of its own
        list_item = next_block(lines, block)
      else
        list_item = build_ulist_item(lines, block, match)
        # Set the base item level for this Block
        first_item_level ||= list_item.level
      end

      items << list_item

      skip_blank(lines)
    end

    block.buffer = items
    block
  end

  def build_ulist_ref(lines, parent = nil)
    items = []
    list_type = :ulist
    block = Block.new(parent, list_type)
    puts "Created :ulist block: #{block}"
    last_item_level = nil
    this_line = lines.shift

    while this_line && match = this_line.match(REGEXP[list_type])
      level = match[1].length

      list_item = ListItem.new
      list_item.level = level
      puts "Created ListItem #{list_item} with match[2]: #{match[2]} and level: #{list_item.level}"

      lines.unshift match[2].lstrip.sub(/^\./, '\.')
      item_segment = list_item_segment(lines, :alt_ending => REGEXP[list_type], :list_level => level)
      while item_segment.any?
        list_item.blocks << next_block(item_segment, block)
      end

      first_block = list_item.blocks.first
      if first_block.is_a?(Block) &&
         (first_block.context == :paragraph || first_block.context == :literal)
        list_item.content = first_block.buffer.map{|l| l.strip}.join("\n")
        list_item.blocks.shift
      end

      if items.any? && (level > items.last.level)
        puts "--> Putting this new level #{level} ListItem under my pops, #{items.last} (level: #{items.last.level})"
        items.last.blocks << list_item
      else
        puts "Stacking new list item in parent block's blocks"
        items << list_item
      end

      last_item_level = list_item.level

      skip_blank(lines)

      this_line = lines.shift
    end
    lines.unshift(this_line) unless this_line.nil?

    block.buffer = items
    block
  end

  # Private: Return the next block from the section.
  #
  # * Skip over blank lines to find the start of the next content block.
  # * Use defined regular expressions to determine the type of content block.
  # * Based on the type of content block, grab lines to the end of the block.
  # * Return a new Asciidoctor::Block or Asciidoctor::Section instance with the
  #   content set to the grabbed lines.
  def next_block(lines, parent = self)
    # Skip ahead to the block content
    skip_blank(lines)

    return nil if lines.empty?

    # NOTE: An anchor looks like this:
    #   [[foo]]
    # with the inside [foo] (including brackets) as match[1]
    if match = lines.first.match(REGEXP[:anchor])
      Asciidoctor.debug "Found an anchor in line:\n\t#{lines.first}"
      # NOTE: This expression conditionally strips off the brackets from
      # [foo], though REGEXP[:anchor] won't actually match without
      # match[1] being bracketed, so the condition isn't necessary.
      anchor = match[1].match(/^\[(.*)\]/) ? $1 : match[1]
      # NOTE: Set @references['foo'] = '[foo]'
      @references[anchor] = match[1]
      lines.shift
    else
      anchor = nil
    end

    Asciidoctor.debug "/"*64
    Asciidoctor.debug "#{File.basename(__FILE__)}:#{__LINE__} -> #{__method__} - First two lines are:"
    Asciidoctor.debug lines.first
    Asciidoctor.debug lines[1]
    Asciidoctor.debug "/"*64

    block = nil
    title = nil
    caption = nil
    source_type = nil
    buffer = []
    while lines.any? && block.nil?
      buffer.clear
      this_line = lines.shift
      next_line = lines.first || ''

      if this_line.match(REGEXP[:comment])
        next

      elsif match = this_line.match(REGEXP[:title])
        title = match[1]
        skip_blank(lines)

      elsif match = this_line.match(REGEXP[:listing_source])
        source_type = match[1]
        skip_blank(lines)

      elsif match = this_line.match(REGEXP[:caption])
        caption = match[1]

      elsif is_section_heading?(this_line, next_line)
        # If we've come to a new section, then we've found the end of this
        # current block.  Likewise if we'd found an unassigned anchor, push
        # it back as well, so it can go with this next heading.
        # NOTE - I don't think this will assign the anchor properly. Anchors
        # only match with double brackets - [[foo]], but what's stored in
        # `anchor` at this point is only the `foo` part that was stripped out
        # after matching.  TODO: Need a way to test this.
        lines.unshift(this_line)
        lines.unshift(anchor) unless anchor.nil?
        Asciidoctor.debug "#{__method__}: SENDING to next_section with lines[0] = #{lines.first}"
        block = next_section(lines)

      elsif this_line.match(REGEXP[:oblock])
        # oblock is surrounded by '--' lines and has zero or more blocks inside
        buffer = grab_lines_until(lines) { |line| line.match(REGEXP[:oblock]) }

        while buffer.any? && buffer.last.strip.empty?
          buffer.pop
        end

        block = Block.new(parent, :oblock, [])
        while buffer.any?
          block.blocks << next_block(buffer, block)
        end

      elsif list_type = [:olist, :colist].detect{|l| this_line.match( REGEXP[l] )}
        items = []
        puts "Creating block of type: #{list_type}"
        block = Block.new(parent, list_type)
        while !this_line.nil? && match = this_line.match(REGEXP[list_type])
          item = ListItem.new

          lines.unshift match[2].lstrip.sub(/^\./, '\.')
          item_segment = list_item_segment(lines, :alt_ending => REGEXP[list_type])
          while item_segment.any?
            item.blocks << next_block(item_segment, block)
          end

          if item.blocks.any? &&
             item.blocks.first.is_a?(Block) &&
             (item.blocks.first.context == :paragraph || item.blocks.first.context == :literal)
            item.content = item.blocks.shift.buffer.map{|l| l.strip}.join("\n")
          end

          items << item

          skip_blank(lines)

          this_line = lines.shift
        end
        lines.unshift(this_line) unless this_line.nil?

        block.buffer = items

      elsif match = this_line.match(REGEXP[:ulist])

        lines.unshift(this_line)
        block = build_ulist(lines, parent)

      elsif match = this_line.match(REGEXP[:dlist])
        pairs = []
        block = Block.new(parent, :dlist)

        this_dlist = Regexp.new(/^#{match[1]}(.*)#{match[3]}\s*$/)

        while !this_line.nil? && match = this_line.match(this_dlist)
          if anchor = match[1].match( /\[\[([^\]]+)\]\]/ )
            dt = ListItem.new( $` + $' )
            dt.anchor = anchor[1]
          else
            dt = ListItem.new( match[1] )
          end
          dd = ListItem.new
          lines.shift if lines.any? && lines.first.strip.empty? # workaround eg. git-config OPTIONS --get-colorbool

          dd_segment = list_item_segment(lines, :alt_ending => this_dlist)
          while dd_segment.any?
            dd.blocks << next_block(dd_segment, block)
          end

          if dd.blocks.any? &&
             dd.blocks.first.is_a?(Block) &&
             (dd.blocks.first.context == :paragraph || dd.blocks.first.context == :literal)
            dd.content = dd.blocks.shift.buffer.map{|l| l.strip}.join("\n")
          end

          pairs << [dt, dd]

          skip_blank(lines)

          this_line = lines.shift
        end
        lines.unshift(this_line) unless this_line.nil?
        block.buffer = pairs

      elsif this_line.match(REGEXP[:verse])
        # verse is preceded by [verse] and lasts until a blank line
        buffer = grab_lines_until(lines, :break_on_blank_lines => true)
        block = Block.new(parent, :verse, buffer)

      elsif this_line.match(REGEXP[:note])
        # note is an admonition preceded by [NOTE] and lasts until a blank line
        buffer = grab_lines_until(lines, :break_on_blank_lines => true)
        block = Block.new(parent, :note, buffer)

      elsif block_type = [:listing, :example].detect{|t| this_line.match( REGEXP[t] )}
        buffer = grab_lines_until(lines) {|line| line.match( REGEXP[block_type] )}
        block = Block.new(parent, block_type, buffer)

      elsif this_line.match( REGEXP[:quote] )
        block = Block.new(parent, :quote)
        buffer = grab_lines_until(lines) {|line| line.match( REGEXP[:quote] ) }

        while buffer.any?
          block.blocks << next_block(buffer, block)
        end

      elsif this_line.match(REGEXP[:lit_blk])
        # example is surrounded by '....' (4 or more '.' chars) lines
        buffer = grab_lines_until(lines) {|line| line.match( REGEXP[:lit_blk] ) }
        block = Block.new(parent, :literal, buffer)

      elsif this_line.match(REGEXP[:lit_par])
        # literal paragraph is contiguous lines starting with
        # one or more space or tab characters

        # So we need to actually include this one in the grab_lines group
        lines.unshift( this_line )
        buffer = grab_lines_until(lines, :preserve_last_line => true) {|line| ! line.match( REGEXP[:lit_par] ) }

        block = Block.new(parent, :literal, buffer)

      elsif this_line.match(REGEXP[:sidebar_blk])
        # example is surrounded by '****' (4 or more '*' chars) lines
        buffer = grab_lines_until(lines) {|line| line.match( REGEXP[:sidebar_blk] ) }
        block = Block.new(parent, :sidebar, buffer)

      else
        # paragraph is contiguous nonblank/noncontinuation lines
        while !this_line.nil? && !this_line.strip.empty?
          if this_line.match( REGEXP[:listing] ) || this_line.match( REGEXP[:oblock] )
            lines.unshift this_line
            break
          end
          buffer << this_line
          this_line = lines.shift
        end

        if buffer.any? && admonition = buffer.first.match(/^NOTE:\s*/)
          buffer[0] = admonition.post_match
          block = Block.new(parent, :note, buffer)
        elsif source_type
          block = Block.new(parent, :listing, buffer)
        else
          puts "Proud parent #{parent} getting a new paragraph with buffer: #{buffer}"
          block = Block.new(parent, :paragraph, buffer)
        end
      end
    end

    block.anchor  ||= anchor
    block.title   ||= title
    block.caption ||= caption

    block
  end

  # Private: Get the Integer ulist level based on the characters
  # in front of the list item text.
  #
  # line - the String line containing the list item
  def ulist_level(line)
    if m = line.strip.match(/^(- | \*{1,5})\s+/x)
      return m[1].length
    end
  end

  # Private: Get the Integer section level based on the characters
  # used in the ASCII line under the section name.
  #
  # line - the String line from under the section name.
  def section_level(line)
    char = line.strip.chars.to_a.uniq
    case char
    when ['=']; 0
    when ['-']; 1
    when ['~']; 2
    when ['^']; 3
    when ['+']; 4
    end
  end

  # == is level 0, === is level 1, etc.
  def single_line_section_level(line)
    [line.length - 1, 0].max
  end

  def is_single_line_section_heading?(line)
    !line.nil? && line.match(REGEXP[:level_title])
  end

  def is_two_line_section_heading?(line1, line2)
    !line1.nil? && !line2.nil? &&
    line1.match(REGEXP[:name]) && line2.match(REGEXP[:line]) &&
    (line1.size - line2.size).abs <= 1
  end

  def is_section_heading?(line1, line2 = nil)
    is_single_line_section_heading?(line1) ||
    is_two_line_section_heading?(line1, line2)
  end

  # Private: Extracts the name, level and (optional) embedded anchor from a
  #          1- or 2-line section heading.
  #
  # Returns an array of a String, Integer, and String or nil.
  #
  # Examples
  #
  #   line1
  #   => "Foo\n"
  #   line2
  #   => "~~~\n"
  #
  #   name, level, anchor = extract_section_heading(line1, line2)
  #
  #   name
  #   => "Foo"
  #   level
  #   => 2
  #   anchor
  #   => nil
  #
  #   line1
  #   => "==== Foo\n"
  #
  #   name, level, anchor = extract_section_heading(line1)
  #
  #   name
  #   => "Foo"
  #   level
  #   => 3
  #   anchor
  #   => nil
  #
  def extract_section_heading(line1, line2 = nil)
    Asciidoctor.debug "#{__method__} -> line1: #{line1.chomp rescue 'nil'}, line2: #{line2.chomp rescue 'nil'}"
    sect_name = sect_anchor = nil
    sect_level = 0

    if is_single_line_section_heading?(line1)
      header_match = line1.match(REGEXP[:level_title])
      sect_name = header_match[2]
      sect_level = single_line_section_level(header_match[1])
    elsif is_two_line_section_heading?(line1, line2)
      header_match = line1.match(REGEXP[:name])
      if anchor_match = header_match[1].match(REGEXP[:anchor_embedded])
        sect_name   = anchor_match[1]
        sect_anchor = anchor_match[2]
      else
        sect_name = header_match[1]
      end
      sect_level = section_level(line2)
    end
    Asciidoctor.debug "#{__method__} -> Returning #{sect_name}, #{sect_level} (anchor: '#{sect_anchor || '<none>'}')"
    return [sect_name, sect_level, sect_anchor]
  end

  # Private: Return the next section from the document.
  #
  # Examples
  #
  #   source
  #   => "GREETINGS\n---------\nThis is my doc.\n\nSALUTATIONS\n-----------\nIt is awesome."
  #
  #   doc = Asciidoctor::Document.new(source)
  #
  #   doc.next_section
  #   ["GREETINGS", [:paragraph, "This is my doc."]]
  #
  #   doc.next_section
  #   ["SALUTATIONS", [:paragraph, "It is awesome."]]
  def next_section(lines)
    section = Section.new(self)

    Asciidoctor.debug "%"*64
    Asciidoctor.debug "#{File.basename(__FILE__)}:#{__LINE__} -> #{__method__} - First two lines are:"
    Asciidoctor.debug lines.first
    Asciidoctor.debug lines[1]
    Asciidoctor.debug "%"*64

    # Skip ahead to the next section definition
    while lines.any? && section.name.nil?
      this_line = lines.shift
      next_line = lines.first || ''
      if match = this_line.match(REGEXP[:anchor])
        section.anchor = match[1]
      elsif is_section_heading?(this_line, next_line)
        section.name, section.level, section.anchor = extract_section_heading(this_line, next_line)
        lines.shift unless is_single_line_section_heading?(this_line)
      end
    end

    if !section.anchor.nil?
      anchor_id = section.anchor.match(/^\[(.*)\]/) ? $1 : section.anchor
      @references[anchor_id] = section.anchor
      section.anchor = anchor_id
    end

    # Grab all the lines that belong to this section
    section_lines = []
    while lines.any?
      this_line = lines.shift
      next_line = lines.first

      if is_section_heading?(this_line, next_line)
        _, this_level, _ = extract_section_heading(this_line, next_line)

        if this_level <= section.level
          # A section can't contain a section level lower than itself,
          # so this signifies the end of the section.
          lines.unshift this_line
          if section_lines.any? && section_lines.last.match(REGEXP[:anchor])
            # Put back the anchor that came before this new-section line
            # on which we're bailing.
            lines.unshift section_lines.pop
          end
          break
        else
          section_lines << this_line
          section_lines << lines.shift unless is_single_line_section_heading?(this_line)
        end
      elsif this_line.match(REGEXP[:listing])
        section_lines << this_line
        section_lines.concat grab_lines_until(lines) {|line| line.match( REGEXP[:listing] ) }
        # Also grab the last line, if there is one
        this_line = lines.shift
        section_lines << this_line unless this_line.nil?
      else
        section_lines << this_line
      end
    end

    # Now parse section_lines into Blocks belonging to the current Section
    while section_lines.any?
      skip_blank(section_lines)

      section << next_block(section_lines, section) if section_lines.any?
    end

    section
  end
  # end private
end
