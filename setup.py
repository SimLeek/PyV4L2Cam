#!/usr/bin/env python3

import sys

from distutils.core import setup, Extension
from setuptools import find_packages

from PyV4L2Cam import __version__

ext = '.pyx'
extensions = [
    Extension(
        'PyV4L2Cam.camera',
        ['PyV4L2Cam/camera' + ext],
        libraries=['v4l2', ]
    ),
    Extension(
        'PyV4L2Cam.controls',
        ['PyV4L2Cam/controls' + ext],
        libraries=['v4l2', ]
    )
]

from Cython.Build import cythonize

extensions = cythonize(extensions)

setup(
    name='PyV4L2Cam',
    version=__version__,
    description='Simple, libv4l2 based frame grabber',
    author='SimLeek',
    author_email='simulator.leek@gmail.com',
    url='https://gitlab.com/simleek/PyV4L2Cam',
    license='GNU Lesser General Public License v3 (LGPLv3)',
    ext_modules=extensions,
    extras_require={
        'examples': ['pillow', 'numpy'],
    },
    packages=find_packages()
)
