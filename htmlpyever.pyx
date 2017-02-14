cimport etreepublic as cetree
cdef object etree
from lxml import etree
cetree.import_lxml__etree()
cimport tree
# this function is not in lxml's pxd files
cdef extern from "libxml/tree.h":
    cdef tree.xmlDtd *xmlNewDtd(tree.xmlDoc *doc,
                                tree.const_xmlChar *name,
                                tree.const_xmlChar *external_id,
                                tree.const_xmlChar *system_id)

from glue cimport h5eParser, h5eUnicode, h5eBytes, h5eCallbacks, node_t
cimport glue

# it's scary that it's 2017 and I still need to spend so much time just doing string conversion

cdef tree.const_xmlChar *xstr_h5e(h5eUnicode h5eutf) except NULL:
    cdef bytes utf8 = h5eutf.ptr[:h5eutf.len]
    cdef unsigned char ch
    for ch in utf8:
        if not tree.xmlIsChar_ch(ch):
            raise ValueError('html5ever gave invalid xml character')
    return tree._xcstr(utf8)

# ok phew we're done with that

# FIXME all memory is leaked
cdef class Parser:
    cdef tree.xmlDoc *doc
    cdef cetree._Document lxml_doc
    cdef h5eParser *parser

    cdef public object script_callback

    def __cinit__(self):
        cdef cetree._Element fuck
        # why doesn't lxml just expose the document factory like they do the element factory...
        fuck = cetree.makeElement('fuck', None, None, None, None, None, None)
        self.lxml_doc = fuck._doc
        self.doc = self.lxml_doc._c_doc
        tree.xmlUnlinkNode(fuck._c_node)
        fuck = None # ok better not use this totally invalid thing ever again

        self.parser = glue.new_parser(&callbacks, <void *> self, <void *> self.doc)
        self.script_callback = None

    def __init__(self, script_callback=None):
        self.script_callback = script_callback

    def __dealloc__(self):
        glue.destroy_parser(self.parser)

    def feed(self, bytes data):
        if glue.feed_parser(self.parser, glue.h5eBytes(len(data), <char *> data)) == -1:
            raise ValueError('html5ever failed for some unknown reason')

    property root:
        def __get__(self):
            return cetree.elementFactory(self.lxml_doc, tree.xmlDocGetRootElement(self.doc))
    property roottree:
        def __get__(self):
            return cetree.elementTreeFactory(self.root)

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
        element = tree.xmlNewDocNode(self.doc, NULL, xstr_h5e(name), NULL)
        if element is NULL: raise MemoryError
        # TODO create the namespace if needed and set it
        return <node_t> element

    cdef node_t get_template_contents_cb(self, node_t element) except NULL:
        # TODO
        print('halp')
        return NULL

    cdef int add_attribute_if_missing_cb(self, node_t element_, h5eUnicode ns, h5eUnicode name, h5eUnicode value) except -1:
        cdef tree.xmlNode *element = <tree.xmlNode *> element_
        # TODO namespaces
        tree.xmlSetProp(element, xstr_h5e(name), xstr_h5e(value))
        return 0

    cdef node_t create_comment_cb(self, h5eUnicode data) except NULL:
        cdef tree.xmlNode *comment = tree.xmlNewDocComment(self.doc, xstr_h5e(data))
        return <node_t> comment

    cdef int append_doctype_to_document_cb(self, h5eUnicode name, h5eUnicode public_id, h5eUnicode system_id) except -1:
        cdef tree.xmlDtd *doctype
        doctype = xmlNewDtd(self.doc, xstr_h5e(name), xstr_h5e(public_id), xstr_h5e(system_id))
        tree.xmlAddChild(<tree.xmlNode *> self.doc, <tree.xmlNode *> doctype)
        return 0

    cdef int append_node_cb(self, node_t parent_, node_t child_) except -1:
        cdef tree.xmlNode *parent = <tree.xmlNode *> parent_
        cdef tree.xmlNode *child = <tree.xmlNode *> child_
        tree.xmlAddChild(parent, child)
        return 0

    cdef int append_text_cb(self, node_t parent_, h5eUnicode text) except -1:
        cdef tree.xmlNode *parent = <tree.xmlNode *> parent_
        cdef tree.xmlNode *child = tree.xmlNewDocText(self.doc, xstr_h5e(text))
        tree.xmlAddChild(parent, child)
        return 0

    cdef int insert_node_before_sibling_cb(self, node_t sibling_, node_t new_sibling_) except -1:
        cdef tree.xmlNode *sibling = <tree.xmlNode *> sibling_
        cdef tree.xmlNode *new_sibling = <tree.xmlNode *> new_sibling_
        tree.xmlAddPrevSibling(sibling, new_sibling)
        return 0

    cdef int insert_text_before_sibling_cb(self, node_t sibling_, h5eUnicode text) except -1:
        cdef tree.xmlNode *sibling = <tree.xmlNode *> sibling_
        cdef tree.xmlNode *new_sibling = tree.xmlNewDocText(self.doc, xstr_h5e(text))
        tree.xmlAddPrevSibling(sibling, new_sibling)
        return 0

    cdef int reparent_children_cb(self, node_t parent_, node_t new_parent_) except -1:
        cdef tree.xmlNode *parent = <tree.xmlNode *> parent_
        cdef tree.xmlNode *new_parent = <tree.xmlNode *> new_parent_
        cdef tree.xmlNode *node

        while parent.children is not NULL:
            node = parent.children
            tree.xmlUnlinkNode(node)
            tree.xmlAddChild(parent, node)
        return 0

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

