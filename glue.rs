extern crate libc;
extern crate html5ever;
extern crate string_cache;
extern crate tendril;

use html5ever::tokenizer::{Tokenizer, Attribute, TokenizerResult};
use html5ever::tokenizer::buffer_queue::BufferQueue;
use html5ever::tree_builder::{TreeBuilder, TreeSink, QuirksMode, NodeOrText};
use html5ever::QualName;
use std::borrow::Cow;
use std::slice;
use std::mem;
use libc::{c_void, c_int, size_t};
use std::panic::{catch_unwind, UnwindSafe};
use tendril::StrTendril;

/// When given as a function parameter, only valid for the duration of the call.
#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct CBytes {
    len: size_t,
    ptr: *const u8,
}

impl CBytes {
    fn from_slice(slice: &[u8]) -> CBytes {
        CBytes {
            len: slice.len(),
            ptr: slice.as_ptr(),
        }
    }

    unsafe fn as_slice(&self) -> &[u8] {
        slice::from_raw_parts(self.ptr, self.len)
    }
}

/// When given as a function parameter, only valid for the duration of the call.
#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct CUnicode(CBytes);

impl CUnicode {
    fn from_str(s: &str) -> CUnicode {
        CUnicode(CBytes::from_slice(s.as_bytes()))
    }
}

pub type OpaqueParserUserData = c_void;
pub type OpaqueNode = c_void;

struct NodeHandle {
    ptr: *const OpaqueNode,
    parser_user_data: *const OpaqueParserUserData,
    callbacks: &'static Callbacks,
    qualified_name: Option<QualName>,
}

macro_rules! call {
    ($self_: expr, $callback: ident ( $( $arg: expr ),* )) => {
        ($self_.callbacks.$callback)($self_.parser_user_data, $( $arg ),* )
    };
}

macro_rules! call_if_some {
    ($self_: expr, $opt_callback: ident ( $( $arg: expr ),* )) => {
        call_if_some!($self_, $opt_callback( $( $arg ),* ) else 0)
    };
    ($self_: expr, $opt_callback: ident ( $( $arg: expr ),* ) else $default: expr) => {
        if let Some(callback) = $self_.callbacks.$opt_callback {
            callback($self_.parser_user_data, $( $arg ),* )
        } else {
            $default
        }
    };
}

impl Clone for NodeHandle {
    fn clone(&self) -> NodeHandle {
        NodeHandle {
            ptr: check_pointer(call_if_some!(self, clone_node_ref(self.ptr) else self.ptr)),
            parser_user_data: self.parser_user_data,
            callbacks: self.callbacks,
            qualified_name: self.qualified_name.clone(),
        }
    }
}

impl Drop for NodeHandle {
    fn drop(&mut self) {
        check_int(call_if_some!(self, destroy_node_ref(self.ptr)));
    }
}

struct CallbackTreeSink {
    parser_user_data: *const c_void,
    callbacks: &'static Callbacks,
    document: NodeHandle,
    quirks_mode: QuirksMode,
}

pub struct Parser {
    tokenizer: Tokenizer<TreeBuilder<NodeHandle, CallbackTreeSink>>
}

struct ParserMutPtr(*mut Parser);

// FIXME: These make catch_unwind happy, but they are total lies as far as I know.
impl UnwindSafe for CBytes {}
impl UnwindSafe for ParserMutPtr {}
impl UnwindSafe for Parser {}

impl CallbackTreeSink {
    fn new_handle(&self, ptr: *const OpaqueNode) -> NodeHandle {
        NodeHandle {
            ptr: ptr,
            parser_user_data: self.parser_user_data,
            callbacks: self.callbacks,
            qualified_name: None,
        }
    }

    fn add_attributes_if_missing(&self, element: *const OpaqueNode, attributes: Vec<Attribute>) {
        for attribute in attributes {
            check_int(call!(self, add_attribute_if_missing(
                element,
                CUnicode::from_str(&attribute.name.ns),
                CUnicode::from_str(&attribute.name.local),
                CUnicode::from_str(&attribute.value))));
        }
    }
}

impl TreeSink for CallbackTreeSink {
    type Handle = NodeHandle;
    type Output = Self;

    fn finish(self) -> Self {
        self
    }

    fn parse_error(&mut self, msg: Cow<'static, str>) {
        check_int(call_if_some!(self, parse_error(CUnicode::from_str(&msg))));
    }

    fn get_document(&mut self) -> NodeHandle {
        self.document.clone()
    }

    fn get_template_contents(&mut self, target: NodeHandle) -> NodeHandle {
        self.new_handle(check_pointer(call!(self, get_template_contents(target.ptr))))
    }

    fn set_quirks_mode(&mut self, mode: QuirksMode) {
        self.quirks_mode = mode
    }

    fn same_node(&self, x: NodeHandle, y: NodeHandle) -> bool {
        check_int(call_if_some!(self, same_node(x.ptr, y.ptr) else (x.ptr == y.ptr) as c_int)) != 0
    }

    fn elem_name(&self, target: NodeHandle) -> QualName {
        target.qualified_name.as_ref().unwrap().clone()
    }

    fn create_element(&mut self, name: QualName, attrs: Vec<Attribute>) -> NodeHandle {
        let element = check_pointer(call!(self, create_element(
                    CUnicode::from_str(&name.ns), CUnicode::from_str(&name.local))));
        self.add_attributes_if_missing(element, attrs);
        let mut handle = self.new_handle(element);
        handle.qualified_name = Some(name);
        handle
    }

    fn create_comment(&mut self, text: StrTendril) -> NodeHandle {
        self.new_handle(check_pointer(call!(
            self, create_comment(CUnicode::from_str(&text)))))
    }

    fn append(&mut self, parent: NodeHandle, child: NodeOrText<NodeHandle>) {
        check_int(match child {
            NodeOrText::AppendNode(node) => {
                call!(self, append_node(parent.ptr, node.ptr))
            }
            NodeOrText::AppendText(ref text) => {
                call!(self, append_text(parent.ptr, CUnicode::from_str(text)))
            }
        });
    }

    fn append_before_sibling(&mut self, sibling: NodeHandle, child: NodeOrText<NodeHandle>)
                             -> Result<(), NodeOrText<NodeHandle>> {
        let result = check_int(match child {
            NodeOrText::AppendNode(ref node) => {
                call!(self, insert_node_before_sibling(sibling.ptr, node.ptr))
            }
            NodeOrText::AppendText(ref text) => {
                call!(self, insert_text_before_sibling(sibling.ptr, CUnicode::from_str(text)))
            }
        });
        if result > 0 {
            Ok(())
        } else {
            Err(child)
        }
    }

    fn append_doctype_to_document(&mut self,
                                  name: StrTendril,
                                  public_id: StrTendril,
                                  system_id: StrTendril) {
        check_int(call!(self, append_doctype_to_document(
            CUnicode::from_str(&name),
            CUnicode::from_str(&public_id),
            CUnicode::from_str(&system_id))));
    }

    fn add_attrs_if_missing(&mut self, target: NodeHandle, attrs: Vec<Attribute>) {
        self.add_attributes_if_missing(target.ptr, attrs)
    }

    fn remove_from_parent(&mut self, target: NodeHandle) {
        check_int(call!(self, remove_from_parent(target.ptr)));
    }

    fn reparent_children(&mut self, node: NodeHandle, new_parent: NodeHandle) {
        check_int(call!(self, reparent_children(node.ptr, new_parent.ptr)));
    }

    fn mark_script_already_started(&mut self, _target: NodeHandle) {}
}

macro_rules! declare_with_callbacks {
    ($( $( #[$attr:meta] )* callback $name: ident: $ty: ty )+) => {
        pub struct Callbacks {
            $( $( #[$attr] )* $name: $ty, )+
        }

        /// Return a heap-allocated stuct that lives forever,
        /// containing the given function pointers.
        ///
        /// This leaks memory, but you normally only need one of these per program.
        #[no_mangle]
        pub unsafe extern "C" fn declare_callbacks($( $name: $ty ),+)
                                                   -> Option<&'static Callbacks> {
            catch_unwind_opt(move || {
                &*Box::into_raw(Box::new(Callbacks {
                    $( $name: $name, )+
                }))
            })
        }

    }
}

declare_with_callbacks! {
    /// Create and return a new reference to the given node.
    /// The returned pointer may be the same as the given one.
    /// If this callback is not provided, the same pointer is always used
    callback clone_node_ref:  Option<extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode) -> *const OpaqueNode>

    /// Destroy a new reference to the given node.
    /// When all references are gone, the node itself can be destroyed.
    /// If this callback is not provided, references are leaked.
    callback destroy_node_ref: Option<extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode) -> c_int>

    /// Return a position value if the two given references are for the same node,
    /// zero for different nodes, and a negative value of an unexpected error.
    /// If this callback is not provided, pointer equality is used.
    callback same_node: Option<extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode, *const OpaqueNode) -> c_int>

    /// Log an author conformance error.
    /// The pointer is guaranteed to point to the given size of well-formed UTF-8 bytes.
    /// The pointer can not be used after the end of this call.
    /// If this callback is not provided, author conformance errors are ignored.
    callback parse_error: Option<extern "C" fn(*const OpaqueParserUserData,
        CUnicode) -> c_int>

    /// Run a script.
    callback run_script: Option<extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode) -> c_int>

    /// Create an element node with the given namespace URL and local name.
    ///
    /// If the element in `template` element in the HTML namespace,
    /// an associated document fragment node should be created for the template contents.
    callback create_element: extern "C" fn(*const OpaqueParserUserData,
        CUnicode, CUnicode) -> *const OpaqueNode

    /// Return a reference to the document fragment node for the template contents.
    ///
    /// This is only ever called for `template` elements in the HTML namespace.
    callback get_template_contents: extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode) -> *const OpaqueNode

    /// Add the attribute (given as namespace URL, local name, and value)
    /// to the given element node if the element doesn’t already have
    /// an attribute with that name in that namespace.
    callback add_attribute_if_missing: extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode, CUnicode, CUnicode, CUnicode) -> c_int

    /// Create a comment node.
    callback create_comment: extern "C" fn(*const OpaqueParserUserData,
        CUnicode) -> *const OpaqueNode

    /// Create a doctype node and append it to the document.
    callback append_doctype_to_document: extern "C" fn(*const OpaqueParserUserData,
        CUnicode, CUnicode, CUnicode) -> c_int

    callback append_node: extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode, *const OpaqueNode) -> c_int

    callback append_text: extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode, CUnicode) -> c_int

    /// If `sibling` has a parent, insert the given node just before it and return 1.
    /// Otherwise, do nothing and return zero.
    callback insert_node_before_sibling: extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode, *const OpaqueNode) -> c_int

    /// If `sibling` has a parent, insert the given text just before it and return 1.
    /// Otherwise, do nothing and return zero.
    callback insert_text_before_sibling: extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode, CUnicode) -> c_int

    callback reparent_children: extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode, *const OpaqueNode) -> c_int

    callback remove_from_parent: extern "C" fn(*const OpaqueParserUserData,
        *const OpaqueNode) -> c_int
}

#[no_mangle]
pub extern "C" fn new_parser(callbacks: &'static Callbacks,
                             data: *const OpaqueParserUserData,
                             document: *const OpaqueNode)
                             -> Option<Box<Parser>> {
    catch_unwind_opt(move || {
        let sink = CallbackTreeSink {
            parser_user_data: data,
            callbacks: callbacks,
            document: NodeHandle {
                ptr: document,
                parser_user_data: data,
                callbacks: callbacks,
                qualified_name: None,
            },
            quirks_mode: QuirksMode::NoQuirks,
        };
        let tree_builder = TreeBuilder::new(sink, Default::default());
        let tokenizer = Tokenizer::new(tree_builder, Default::default());
        Box::new(Parser {
            tokenizer: tokenizer
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn feed_parser(parser: &mut Parser, chunk: CBytes) -> c_int {
    let parser = ParserMutPtr(parser);
    catch_unwind_int(move || {
        let parser = &mut *parser.0;
        // FIXME: Support UTF-8 byte sequences split across chunk boundary
        // FIXME: Go through the data once here instead of twice.
        let string = String::from_utf8_lossy(chunk.as_slice());
        let mut buffers = BufferQueue::new();
        buffers.push_back((&*string).into());
        while let TokenizerResult::Script(node) = parser.tokenizer.feed(&mut buffers) {
            let sink = parser.tokenizer.sink().sink();
            check_int(call_if_some!(sink, run_script(node.ptr)));
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn end_parser(parser: &mut Parser) -> c_int {
    let parser = ParserMutPtr(parser);
    catch_unwind_int(move || {
        let parser = &mut *parser.0;
        parser.tokenizer.end();
    })
}

#[no_mangle]
pub extern "C" fn destroy_parser(parser: Box<Parser>) -> c_int {
    catch_unwind_int(move || {
        mem::drop(parser)
    })
}

#[no_mangle]
pub extern "C" fn destroy_qualified_name(name: Box<QualName>) -> c_int {
    catch_unwind_int(|| {
        mem::drop(name)
    })
}

fn catch_unwind_opt<R, F: FnOnce() -> R + UnwindSafe + 'static>(f: F) -> Option<R> {
    catch_unwind(f).ok()
}

fn catch_unwind_int<F: FnOnce() + UnwindSafe + 'static>(f: F) -> c_int {
    match catch_unwind(f) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

fn check_int(value: c_int) -> c_int {
    assert!(value >= 0, "Python exception");
    value
}

fn check_pointer<T>(ptr: *const T) -> *const T {
    assert!(!ptr.is_null(), "Python exception");
    ptr
}
