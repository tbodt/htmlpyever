#!/usr/bin/env python
import subprocess
from setuptools import setup, Extension
from setuptools.command.build_ext import build_ext as setuptools_build_ext
from Cython.Build.Cythonize import cythonize
import lxml

MODE = 'release'

class build_ext(setuptools_build_ext):
    def build_extension(self, ext):
        subprocess.check_call(['cargo', 'build'] + 
                              (['--release'] if MODE == 'release' else []))
        setuptools_build_ext.build_extension(self, ext)

includes = ['/usr/include/libxml2'] + lxml.get_include()
setup(
    name='htmlpyever',

    ext_modules=cythonize([Extension(
        name='htmlpyever',
        sources=['htmlpyever.pyx'],
        libraries=['html5ever_glue', 'xml2'],
        library_dirs=['target/{}'.format(MODE)],
        include_dirs=includes,
        depends=['target/{}/libhtml5ever_glue.a'.format(MODE)],
    )], include_path=includes),

    setup_requires=['cython'],
    install_requires=['lxml'],
    cmdclass={'build_ext': build_ext},
)
