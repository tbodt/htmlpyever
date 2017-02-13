#!/usr/bin/env python
from setuptools import setup, Extension
from Cython.Distutils import build_ext
import lxml

setup(
    name='htmlpyever',

    ext_modules=[Extension(
        name='htmlpyever',
        sources=['htmlpyever.pyx'],
        libraries=['html5ever_glue', 'xml2'],
        library_dirs=['target/debug'],
        include_dirs=['.', '/usr/include/libxml2'] + lxml.get_include(),
    )],

    setup_requires=['cython'],
    install_requires=['lxml'],
    cmdclass={'build_ext': build_ext}
)
