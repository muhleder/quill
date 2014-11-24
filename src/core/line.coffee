_          = require('lodash')
Delta      = require('rich-text/lib/delta')
dom        = require('../lib/dom')
Embedder   = require('./embedder')
Formatter  = require('./formatter')
Leaf       = require('./leaf')
Line       = require('./line')
LinkedList = require('../lib/linked-list')
Normalizer = require('../lib/normalizer')


class Line extends LinkedList.Node
  @CLASS_NAME : 'ql-line'
  @ID_PREFIX  : 'ql-line-'

  constructor: (@doc, @node) ->
    @id = _.uniqueId(Line.ID_PREFIX)
    @formats = {}
    dom(@node).addClass(Line.CLASS_NAME)
    this.rebuild()
    super(@node)

  buildLeaves: (node, formats) ->
    _.each(dom(node).childNodes(), (node) =>
      node = Normalizer.normalizeNode(node)
      nodeFormats = _.clone(formats)
      # TODO: optimize
      _.each(@doc.formats, (format, name) ->
        if format.type != Formatter.types.LINE and value = Formatter.value(format, node)
          nodeFormats[name] = value
      )
      if Leaf.isLeafNode(node)
        _.each(@doc.embeds, (embed, name) ->
          if value = Embedder.value(embed, node)
            nodeFormats[name] = value
        )
        @leaves.append(new Leaf(node, nodeFormats))
      else
        this.buildLeaves(node, nodeFormats)
    )

  deleteText: (offset, length) ->
    return unless length > 0
    [leaf, offset] = this.findLeafAt(offset)
    while leaf? and length > 0
      deleteLength = Math.min(length, leaf.length - offset)
      leaf.deleteText(offset, deleteLength)
      length -= deleteLength
      leaf = leaf.next
      offset = 0
    this.rebuild()

  findLeaf: (leafNode) ->
    curLeaf = @leaves.first
    while curLeaf?
      return curLeaf if curLeaf.node == leafNode
      curLeaf = curLeaf.next
    return null

  findLeafAt: (offset, inclusive = false) ->
    # TODO exact same code as findLineAt
    return [@leaves.last, @leaves.last.length] if offset >= @length - 1
    leaf = @leaves.first
    while leaf?
      if offset < leaf.length or (offset == leaf.length and inclusive)
        return [leaf, offset]
      offset -= leaf.length
      leaf = leaf.next
    return [@leaves.last, offset - @leaves.last.length]   # Should never occur unless length calculation is off

  format: (name, value) ->
    if _.isObject(name)
      formats = name
    else
      formats = {}
      formats[name] = value
    _.each(formats, (value, name) =>
      format = @doc.formats[name]
      return unless format?
      # TODO reassigning @node might be dangerous...
      if format.type == Formatter.types.LINE
        if format.exclude and @formats[format.exclude]
          excludeFormat = @doc.formats[format.exclude]
          if excludeFormat?
            @node = Formatter.remove(excludeFormat, @node)
            delete @formats[format.exclude]
        @node = Formatter.add(format, @node, value)
      if value
        @formats[name] = value
      else
        delete @formats[name]
    )
    this.resetContent()

  formatText: (offset, length, name, value) ->
    [leaf, leafOffset] = this.findLeafAt(offset)
    format = @doc.formats[name]
    return unless format? and format.type != Formatter.types.LINE
    while leaf? and length > 0
      nextLeaf = leaf.next
      # Make sure we need to change leaf format
      if (value and leaf.formats[name] != value) or (!value and leaf.formats[name]?)
        targetNode = leaf.node
        # Identify node to modify
        if leaf.formats[name]?
          dom(targetNode).splitAncestors(@node)
          while !Formatter.match(format, targetNode)
            targetNode = targetNode.parentNode
        # Isolate target node
        if leafOffset > 0
          [leftNode, targetNode] = dom(targetNode).split(leafOffset)
        if leaf.length > leafOffset + length  # leaf.length does not update with split()
          [targetNode, rightNode] = dom(targetNode).split(length)
        Formatter.add(format, targetNode, value)
      length -= leaf.length - leafOffset
      leafOffset = 0
      leaf = nextLeaf
    this.rebuild()

  insertEmbed: (offset, type, value) ->
    [leaf, leafOffset] = this.findLeafAt(offset)
    [prevNode, nextNode] = dom(leaf.node).split(leafOffset)
    nextNode = dom(nextNode).splitAncestors(@node).get() if nextNode
    embed = @doc.embeds[type]
    return unless embed?
    node = Embedder.create(embed, value)
    @node.insertBefore(node, nextNode)
    this.rebuild()

  insertText: (offset, text, formats = {}) ->
    return unless text.length > 0
    [leaf, leafOffset] = this.findLeafAt(offset)
    # offset > 0 for multicursor
    if _.isEqual(leaf.formats, formats)
      leaf.insertText(leafOffset, text)
      this.resetContent()
    else
      node = _.reduce(formats, (node, value, name) =>
        format = @doc.formats[name]
        node = Formatter.add(format, node, value) if format?
        return node
      , document.createTextNode(text))
      [prevNode, nextNode] = dom(leaf.node).split(leafOffset)
      nextNode = dom(nextNode).splitAncestors(@node).get() if nextNode
      @node.insertBefore(node, nextNode)
      this.rebuild()

  optimize: ->
    Normalizer.optimizeLine(@node)
    this.rebuild()

  rebuild: (force = false) ->
    if !force and @outerHTML? and @outerHTML == @node.outerHTML
      if _.all(@leaves.toArray(), (leaf) =>
        return dom(leaf.node).isAncestor(@node)
      )
        return false
    @node = Normalizer.normalizeNode(@node)
    if dom(@node).length() == 0 and !@node.querySelector(dom.DEFAULT_BREAK_TAG)
      @node.appendChild(document.createElement(dom.DEFAULT_BREAK_TAG))
    @leaves = new LinkedList()
    @formats = _.reduce(@doc.formats, (formats, format, name) =>
      if format.type == Formatter.types.LINE
        if Formatter.match(format, @node)
          formats[name] = Formatter.value(format, @node)
        else
          delete formats[name]
      return formats
    , @formats)
    this.buildLeaves(@node, {})
    this.resetContent()
    return true

  resetContent: ->
    @node.id = @id unless @node.id == @id
    @outerHTML = @node.outerHTML
    @length = 1
    @delta = new Delta()
    _.each(@leaves.toArray(), (leaf) =>
      @length += leaf.length
      # TODO use constant for embed type
      if dom.EMBED_TAGS[leaf.node.tagName]?
        @delta.insert(1, leaf.formats)
      else
        @delta.insert(leaf.text, leaf.formats)
    )
    @delta.insert('\n', @formats)


module.exports = Line
