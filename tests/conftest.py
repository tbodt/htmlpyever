import os

import pytest

import htmlpyever

def pytest_collect_file(path, parent):
    dir = os.path.basename(path.dirname)
    if dir == 'tree-construction' and path.ext == '.dat':
        return TreeConstructionFile(path, parent)

class TreeConstructionFile(pytest.File):
    def collect(self):
        with open(self.fspath, 'rb') as dat:
            testdata = {}
            in_quote = False
            for i, line in enumerate(dat, 1):
                if line == b'\n' and len(testdata) >= 3 and not in_quote:
                    assert not in_quote
                    yield TreeConstructionTest(i, self, **testdata)
                    testdata = {}
                elif line.startswith(b'#'):
                    heading = line[1:-1].replace(b'-', b'_').decode()
                    testdata.setdefault(heading, b'')
                    if heading == 'document':
                        in_quote = False
                else:
                    if heading == 'document':
                        for i in range(line.count(b'"')):
                            in_quote = not in_quote
                    testdata[heading] += line

class TreeConstructionTest(pytest.Item):
    def __init__(self, index, parent, data=None, errors=None, document=None, **kwargs):
        super().__init__(f'tree-construction-{index}', parent)
        self.data = data
        self.errors = errors
        self.document = document

    def runtest(self):
        parser = htmlpyever.Parser()
        print(self.data)
        parser.feed(self.data)

