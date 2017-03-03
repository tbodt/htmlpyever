import os
import re
import itertools
import operator

import pytest
from lxml import etree
import htmlpyever
import fucklxml

def pytest_collect_file(path, parent):
    dir = os.path.basename(path.dirname)
    if dir == 'tree-construction' and path.ext == '.dat':
        return TreeConstructionFile(path, parent)

with open('tests/xfail.txt') as xfail:
    # chop off the ending newlines
    xfail_list = list(map(operator.itemgetter(slice(-1)), xfail))

class TreeConstructionFile(pytest.File):
    def collect(self):
        with open(self.fspath, 'rb') as dat:
            testdata = {}
            # The whole in_quote thing is really ghetto but at least it works on the test data
            in_quote = False
            for i, line in enumerate(itertools.chain(dat, [b'\n']), 1):
                if line == b'\n' and len(testdata) >= 3 and not in_quote:
                    assert not in_quote
                    yield TreeConstructionTest(os.path.basename(self.fspath), i, self, **testdata)
                    testdata = {}
                elif line.startswith(b'#'):
                    heading = line[1:-1].replace(b'-', b'_').decode()
                    testdata.setdefault(heading, b'')
                    if heading == 'document':
                        in_quote = False
                else:
                    if heading == 'document':
                        if in_quote or line[1:].lstrip().startswith(b'"'):
                            for _ in range(line.count(b'"')):
                                in_quote = not in_quote
                    testdata[heading] += line

etree.register_namespace('math', 'http://www.w3.org/1998/Math/MathML')
etree.register_namespace('svg', 'http://www.w3.org/2000/svg')
etree.register_namespace('xlink', 'http://www.w3.org/1999/xlink')
etree.register_namespace('xml', 'http://www.w3.org/XML/1998/namespace')
etree.register_namespace('xmlns', 'http://www.w3.org/2000/xmlns/')

HTML_NS = 'http://www.w3.org/1999/xhtml'

def parse_name(name):
    if name.startswith(b'math '):
        namespace = 'http://www.w3.org/1998/Math/MathML'
        prefix = 'math'
    elif name.startswith(b'svg '):
        namespace = 'http://www.w3.org/2000/svg'
        prefix = 'svg'
    elif name.startswith(b'xlink '):
        namespace = 'http://www.w3.org/1999/xlink'
        prefix = 'xlink'
    elif name.startswith(b'xml '):
        namespace = 'http://www.w3.org/XML/1998/namespace'
        prefix = 'xml'
    elif name.startswith(b'xmlns '):
        namespace = 'http://www.w3.org/2000/xmlns/'
        prefix = 'xmlns'
    else:
        namespace = HTML_NS
        prefix = None
    if namespace != HTML_NS:
        name = name.split()[1]

    return name, prefix, namespace

def etreeify_name(name, attribute=False):
    name, prefix, namespace = parse_name(name)
    if attribute:
        if namespace == HTML_NS:
            return name
        return b'{' + namespace.encode() + b'}' + name
    return b'{' + namespace.encode() + b'}' + name, {prefix: namespace}

def etreeify(raw_name):
    try:
        name, nsmap = etreeify_name(raw_name)
        return etree.Element(name, nsmap=nsmap)
    except ValueError:
        elem = etree.Element('fuck')
        name, prefix, namespace = parse_name(raw_name)
        fucklxml.set_name(elem, name, prefix, namespace)
        return elem

class TreeConstructionTest(pytest.Item):
    def __init__(self, filename, index, parent, data=None, errors=None, document=None, document_fragment=None, script_off=False, **kwargs):
        super().__init__(f'{filename}:{index}', parent)
        if data != b'':
            assert data.endswith(b'\n')
            data = data[:-1]
        self.data = data
        self.errors = errors
        self.document = document
        self.script_on = script_off != b''
        if document_fragment is not None:
            assert document_fragment.endswith(b'\n')
            self.fragment_context = etreeify(document_fragment[:-1])
        else:
            self.fragment_context = None

    def runtest(self):
        if self.name in xfail_list:
            try:
                self._runtest()
            except:
                pytest.xfail()
        else:
            self._runtest()

    def _runtest(self):
        print(self.name)
        print('data', self.data)

        top_level = [] # to deal with top-level comments
        stack = []
        def append(elem):
            if len(stack):
                stack[-1].append(elem)
            else:
                top_level.append(elem)
            stack.append(elem)
        if self.fragment_context is not None:
            append(self.fragment_context)

        doctype_name = None
        doctype_public_id = doctype_system_id = ''

        template_contents = {}

        document = self.document
        assert document.startswith(b'| ') and document.endswith(b'\n')
        for line in document[2:-1].split(b'\n| '):

            line_depth = (len(line) - len(line.lstrip())) // 2
            if self.fragment_context is not None:
                line_depth += 1
            line = line.lstrip()

            while line_depth < len(stack):
                stack.pop()
            
            if line == b'content':
                # template contents
                contents = etree.Element('template-contents')
                template_contents[stack[-1]] = contents
                stack.append(contents)

            elif line.startswith(b'<!-- ') and line.endswith(b' -->'):
                # comment
                content = line[5:-4].decode('utf-8')
                comment = etree.Comment()
                comment.text = content
                append(comment)

            elif line.startswith(b'<!DOCTYPE ') and line.endswith(b'>'):
                # doctype
                content = line[10:-1]
                doctype_name, _, content = content.partition(b' "')
                if content:
                    doctype_public_id, _, content = content.partition(b'" "')
                    doctype_system_id, _, _ = content.rpartition(b'"')
                    doctype_public_id = doctype_public_id.decode()
                    doctype_system_id = doctype_system_id.decode()
                doctype_name = doctype_name.decode()

            elif line.startswith(b'<') and line.endswith(b'>'):
                # element
                name = line[1:-1]
                elem = etreeify(name)
                append(elem)

            elif line.startswith(b'"') and line.endswith(b'"'):
                # text
                text = line[1:-1].decode('utf-8')
                top = stack[-1]
                if len(top) == 0:
                    if top.text is None:
                        top.text = text
                    else:
                        top.text += text
                else:
                    if top[-1].tail is None:
                        top[-1].tail = text
                    else:
                        top[-1].tail += text

            else:
                assert b'=' in line
                name, _, value = line.partition(b'=')
                assert value.startswith(b'"') and value.endswith(b'"')
                value = value[1:-1]
                try:
                    stack[-1].set(etreeify_name(name, attribute=True), value)
                except ValueError:
                    name, prefix, namespace = parse_name(name)
                    fucklxml.set_attribute(elem, name, value, prefix, namespace)

        pre_root = []
        root = None
        for node in top_level:
            if root is None:
                if isinstance(node.tag, str):
                    root = node
                    for node in pre_root:
                        root.addprevious(node)
                else:
                    pre_root.append(node)
            else:
                root.addnext(node)

        document = etree.ElementTree(root)
        if self.fragment_context is None:
            assert document.getroot().tag == '{' + HTML_NS + '}html'
        document.docinfo.public_id = doctype_public_id
        document.docinfo.system_url = doctype_system_id
        
        parser = htmlpyever.Parser(fragment_context=self.fragment_context, scripting=self.script_on)
        parser.feed(self.data)
        parser.end()
        if self.fragment_context is not None:
            self.fragment_context.extend(parser.root)
            root = self.fragment_context
        else:
            root = parser.root
        try:
            assert etree.tostring(root) == etree.tostring(document.getroot())
            if parser.roottree.docinfo.internalDTD is not None:
                assert doctype_name == parser.roottree.docinfo.internalDTD.name
                assert doctype_public_id == parser.roottree.docinfo.public_id
                assert doctype_system_id == parser.roottree.docinfo.system_url
            else:
                assert doctype_name is None
                assert doctype_public_id == ''
                assert doctype_system_id == ''
        except:
            print(etree.tostring(root))
            print(etree.tostring(document.getroot()))
            raise

    def repr_failure(self, excinfo):
        traceback = excinfo.traceback
        ntraceback = traceback.cut(path=__file__)
        excinfo.traceback = ntraceback.filter()

        return excinfo.getrepr(funcargs=True,
                               showlocals=False,
                               style="short", tbfilter=False)
