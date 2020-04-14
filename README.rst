*********
PyV4L2Cam
*********
A high FPS linux webcam library for python. Based off of https://gitlab.com/radish/PyV4L2Camera

============
Installation
============
+++++++
Libv4l2
+++++++
Libv4l2 is packaged by various distributions:

.. code-block:: bash

    # Debian and Ubuntu:
    $ apt-get install libv4l-dev

    # Fedora
    $ dnf install libv4l-devel

    # Arch Linux
    $ pacman -S v4l-utils

++++++
PyV4L2
++++++
To install PyV4L2Cam make sure you have Cython installed and type:

.. code-block:: bash

    $ pip install git+https://github.com/simleek/PyV4L2Cam.git@

PyV4L2Cam is only compatible with Python 3.

=====
Usage
=====
.. code-block:: python

    from PyV4L2Cam.camera import Camera

    camera = Camera('/dev/video0')
    frame = camera.get_frame()

The returned frame is a bytes object in MJPEG formet. It may fall back to RGB24.
You can use opencv's imdecode to convert these to numpy arrays. This is done in
the examples directory.

=======
Authors
=======
`SimLeek <https://github.com/simleek>`_
Other PyV4l developers that I've found:
`Dominik Pieczyński <https://gitlab.com/u/rivi>`_ and `contributors
<https://gitlab.com/radish/PyV4L2Camera/graphs/master/contributors>`_.
