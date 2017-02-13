cdef extern from "glue.h":
    ctypedef struct h5eBytes:
        size_t len
        const char *ptr
    ctypedef h5eBytes h5eUnicode

    ctypedef struct h5eQualName:
        h5eUnicode ns
        h5eUnicode local

    ctypedef void *node_t
    ctypedef struct h5eParser:
        pass

    ctypedef struct h5eCallbacks:
        node_t (*clone_node_ref)(void *data, node_t node)
        int (*destroy_node_ref)(void *data, node_t node)
        int (*same_node)(void *data, node_t node1, node_t node2)
        int (*parse_error)(void *data, h5eUnicode error)
        int (*run_script)(void *data, node_t script)
        node_t (*create_element)(void *data, h5eUnicode ns, h5eUnicode name)
        node_t (*get_template_contents)(void *data, node_t node)
        int (*add_attribute_if_missing)(void *data, node_t node, h5eUnicode ns, h5eUnicode name, h5eUnicode value)
        node_t (*create_comment)(void *data, h5eUnicode text)
        int (*append_doctype_to_document)(void *data, h5eUnicode name, h5eUnicode public_id, h5eUnicode system_id)
        int (*append_node)(void *data, node_t parent, node_t child)
        int (*append_text)(void *data, node_t node, h5eUnicode text)
        int (*insert_node_before_sibling)(void *data, node_t sibling, node_t node)
        int (*insert_text_before_sibling)(void *data, node_t sibling, h5eUnicode text)
        int (*reparent_children)(void *data, node_t node, node_t new_parent)
        int (*remove_from_parent)(void *data, node_t node)

    h5eParser *new_parser(h5eCallbacks *, void *data, node_t document)
    int destroy_parser(h5eParser *)
    # if any of the callbacks threw an exception then this will return -1
    int feed_parser(h5eParser *, h5eBytes) except -1
    int end_parser(h5eParser *)
