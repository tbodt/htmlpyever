from libc.string cimport strcmp

cimport etreepublic as cetree
cdef object etree
from lxml import etree
cetree.import_lxml__etree()
cimport tree

# crap that isn't used by lxml and therefore is not in their pxd files
cdef extern from "libxml/tree.h":
    cdef tree.xmlDtd *xmlNewDtd(tree.xmlDoc *doc,
                                tree.const_xmlChar *name,
                                tree.const_xmlChar *external_id,
                                tree.const_xmlChar *system_id)


from glue cimport h5eParser, h5eUnicode, h5eBytes, h5eCallbacks, node_t
cimport glue

# it's scary that it's 2017 and I still need to spend so much time just doing string conversion

cdef bytes bytes_h5e(h5eUnicode h5eutf):
    cdef bytes utf8 = h5eutf.ptr[:h5eutf.len]
    cdef unsigned char ch
    for ch in utf8:
        if not tree.xmlIsChar_ch(ch):
            raise ValueError('html5ever gave invalid xml character')
    return utf8

# ok phew we're done with that

cdef cetree._Document documentFactory(tree.xmlDoc *c_doc):
    cdef cetree._Document doc
    if c_doc._private is not NULL:
        return <cetree._Document?> c_doc._private
    doc = cetree.makeElement('fuck', None, None, None, None, None, None)._doc
    tree.xmlFreeDoc(doc._c_doc)
    doc._c_doc = c_doc
    c_doc._private = <void *> doc
    return doc

# FIXME all memory is leaked
cdef class Parser:
    cdef tree.xmlDoc *doc
    cdef cetree._Document lxml_doc
    cdef h5eParser *parser

    cdef readonly dict template_contents
    cdef public object script_callback

    def __cinit__(self):
        self.doc = NULL
        self.parser = NULL

    def __init__(self, object script_callback=None, cetree._Element fragment_context=None):
        cdef cetree._Element fuck
        cdef const char *ctx_name

        self.doc = tree.xmlNewDoc(NULL)
        self.lxml_doc = documentFactory(self.doc)

        if fragment_context is not None and (
                fragment_context._c_node.ns is NULL or
                strcmp(<const char *> fragment_context._c_node.ns.href, "http://www.w3.org/1999/xhtml") == 0
        ):
            ctx_name = <const char *> fragment_context._c_node.name
        else:
            ctx_name = NULL

        self.parser = glue.new_parser(&callbacks, <void *> self, <void *> self.doc, ctx_name)

        self.script_callback = script_callback
        self.template_contents = {}

    def __dealloc__(self):
        if self.parser is not NULL:
            glue.destroy_parser(self.parser)

    def feed(self, bytes data):
        self.check_initted()
        if glue.feed_parser(self.parser, glue.h5eBytes(len(data), <char *> data)) == -1:
            raise ValueError('html5ever failed for some unknown reason')

    property root:
        def __get__(self):
            self.check_initted()
            return cetree.elementFactory(self.lxml_doc, tree.xmlDocGetRootElement(self.doc))
    property roottree:
        def __get__(self):
            self.check_initted()
            return cetree.elementTreeFactory(self.root)

    cdef int check_initted(self) except -1:
        if self.doc == NULL:
            raise ValueError('__init__ was never called')
        return 0

    # RUN DA SCRIPTS YAAAH

    cdef int run_script_cb(self, node_t script_) except -1:
        cdef tree.xmlNode *script = <tree.xmlNode *> script_
        self.run_script(cetree.elementFactory(self.lxml_doc, script))

    def run_script(self, script):
        if self.script_callback is not None:
            self.script_callback(script)

    # DA CALLBACKS WOOHOO

    cdef node_t create_element_cb(self, h5eUnicode ns, h5eUnicode name) except NULL:
        cdef tree.xmlNode *element
        cdef cetree._Element etree_element
        cdef cetree._Element template
        element = tree.xmlNewDocNode(self.doc, NULL, tree._xcstr(bytes_h5e(name)), NULL)
        if element is NULL: raise MemoryError
        # TODO create the namespace if needed and set it
        return <node_t> element

    cdef node_t get_template_contents_cb(self, node_t element_) except NULL:
        cdef tree.xmlNode *element = <tree.xmlNode *> element_
        cdef cetree._Element contents
        cdef cetree._Element etree_element

        template = cetree.elementFactory(documentFactory(element.doc), element)
        if template not in self.template_contents:
            contents = etree.Element('fuck')
            tree.xmlNodeSetName(contents._c_node, "template contents")
            contents._doc._c_doc._private = <void *> contents._doc
            self.template_contents[template] = contents

        return (<cetree._Element?> self.template_contents[template])._c_node

    cdef int add_attribute_if_missing_cb(self, node_t element_, h5eUnicode ns, h5eUnicode name, h5eUnicode value) except -1:
        cdef tree.xmlNode *element = <tree.xmlNode *> element_
        # TODO namespaces
        tree.xmlSetProp(element, tree._xcstr(bytes_h5e(name)), tree._xcstr(bytes_h5e(value)))
        return 0

    cdef node_t create_comment_cb(self, h5eUnicode data) except NULL:
        cdef tree.xmlNode *comment = tree.xmlNewDocComment(self.doc, tree._xcstr(bytes_h5e(data)))
        return <node_t> comment

    cdef int append_doctype_to_document_cb(self, h5eUnicode name, h5eUnicode public_id, h5eUnicode system_id) except -1:
        cdef tree.xmlDtd *doctype
        doctype = xmlNewDtd(self.doc, 
                            tree._xcstr(bytes_h5e(name)), 
                            tree._xcstr(bytes_h5e(public_id)), 
                            tree._xcstr(bytes_h5e(system_id)))
        tree.xmlAddChild(<tree.xmlNode *> self.doc, <tree.xmlNode *> doctype)
        return 0

    cdef int append_node_cb(self, node_t parent_, node_t child_) except -1:
        cdef tree.xmlNode *parent = <tree.xmlNode *> parent_
        cdef tree.xmlNode *child = <tree.xmlNode *> child_
        tree.xmlAddChild(parent, child)
        return 0

    cdef int append_text_cb(self, node_t parent_, h5eUnicode text) except -1:
        cdef tree.xmlNode *parent = <tree.xmlNode *> parent_
        cdef tree.xmlNode *child = tree.xmlNewDocText(self.doc, tree._xcstr(bytes_h5e(text)))
        tree.xmlAddChild(parent, child)
        return 0

    # These callbacks are only triggered when text or a tag not on the
    # whitelist is found in a table. The text or tag is then inserted before
    # the table.
    # <table><tag></tag></table>
    cdef int insert_node_before_sibling_cb(self, node_t sibling_, node_t new_sibling_) except -1:
        cdef tree.xmlNode *sibling = <tree.xmlNode *> sibling_
        cdef tree.xmlNode *new_sibling = <tree.xmlNode *> new_sibling_
        tree.xmlUnlinkNode(new_sibling)
        tree.xmlAddPrevSibling(sibling, new_sibling)
        return 1

    cdef void omg_break(self): pass

    # <table>foof</table>
    cdef int insert_text_before_sibling_cb(self, node_t sibling_, h5eUnicode text) except -1:
        cdef tree.xmlNode *sibling = <tree.xmlNode *> sibling_
        cdef tree.xmlNode *new_sibling = tree.xmlNewDocText(self.doc, tree._xcstr(bytes_h5e(text)))
        tree.xmlAddPrevSibling(sibling, new_sibling)
        return 0

    # This is only called when dealing with end tags that don't match start tags
    # e.g. <b><p></b></p>
    cdef int reparent_children_cb(self, node_t parent_, node_t new_parent_) except -1:
        cdef tree.xmlNode *parent = <tree.xmlNode *> parent_
        cdef tree.xmlNode *new_parent = <tree.xmlNode *> new_parent_
        cdef tree.xmlNode *node

        while parent.children is not NULL:
            node = parent.children
            tree.xmlUnlinkNode(node)
            tree.xmlAddChild(new_parent, node)
        return 0

    # rare case, triggered by <tag></tag><frameset></frameset>
    cdef int remove_from_parent_cb(self, node_t node_) except -1:
        cdef tree.xmlNode *node = <tree.xmlNode *> node_
        tree.xmlUnlinkNode(node)

cdef h5eCallbacks callbacks = h5eCallbacks(
    clone_node_ref=             NULL,
    destroy_node_ref=           NULL,
    same_node=                  NULL,
    parse_error=                NULL,
    run_script=                 <int    (*)(void*, node_t)>                                     Parser.run_script_cb,
    create_element=             <node_t (*)(void*, h5eUnicode, h5eUnicode)>                     Parser.create_element_cb,
    get_template_contents=      <node_t (*)(void*, node_t)>                                     Parser.get_template_contents_cb,
    add_attribute_if_missing=   <int    (*)(void*, node_t, h5eUnicode, h5eUnicode, h5eUnicode)> Parser.add_attribute_if_missing_cb,
    create_comment=             <node_t (*)(void*, h5eUnicode)>                                 Parser.create_comment_cb,
    append_doctype_to_document= <int    (*)(void*, h5eUnicode, h5eUnicode, h5eUnicode)>         Parser.append_doctype_to_document_cb,
    append_node=                <int    (*)(void*, node_t, node_t)>                             Parser.append_node_cb,
    append_text=                <int    (*)(void*, node_t, h5eUnicode)>                         Parser.append_text_cb,
    insert_node_before_sibling= <int    (*)(void*, node_t, node_t)>                             Parser.insert_node_before_sibling_cb,
    insert_text_before_sibling= <int    (*)(void*, node_t, h5eUnicode)>                         Parser.insert_text_before_sibling_cb,
    reparent_children=          <int    (*)(void*, node_t, node_t)>                             Parser.reparent_children_cb,
    remove_from_parent=         <int    (*)(void*, node_t)>                                     Parser.remove_from_parent_cb,
)

