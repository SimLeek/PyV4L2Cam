# cython: language_level=2

from v4l2 cimport *
from libc.errno cimport errno, EINTR, EINVAL
from libc.string cimport memset, strerror, memcpy
from libc.stdlib cimport malloc, calloc, free
from posix.select cimport fd_set, timeval, FD_ZERO, FD_SET, select
from posix.fcntl cimport O_RDWR
from posix.mman cimport PROT_READ, PROT_WRITE, MAP_SHARED
import warnings

from PyV4L2Cam.controls import CameraControl
from PyV4L2Cam.exceptions import CameraError

cdef class Camera:
    cdef int fd
    cdef fd_set fds

    cdef v4l2_format fmt
    cdef v4l2_format dst_fmt

    cdef public unsigned int width
    cdef public unsigned int height
    cdef public str src_pixel_format
    cdef public str dest_pixel_format
    cdef public v4l2_input input_info
    cdef public v4l2_capability input_capabilities

    cdef unsigned int conv_dest_size
    cdef unsigned char *conv_dest
    cdef bint do_convert

    cdef v4l2_requestbuffers buf_req
    cdef v4l2_buffer buf
    cdef buffer_info *buffers

    cdef timeval tv
    cdef v4lconvert_data *convert_data

    def __cinit__(self, device_path,
                  long int width=0, long int height=0,
                  src_fmt=None, dest_fmt=None):

        cdef unsigned int src_pixelformat
        cdef unsigned int dst_pixelformat
        cdef unsigned int raw_size
        cdef v4l2_fmtdesc fmtdesc

        device_path = device_path.encode()

        self.fd = v4l2_open(device_path, O_RDWR)
        if -1 == self.fd:
            raise CameraError('Error opening device {}'.format(device_path))

        # ----------------------------------------------------------------
        # Device info
        # ----------------------------------------------------------------
        memset(&self.input_info, 0, sizeof(self.input_info))
        self.input_info.index = 0
        if -1 == xioctl(self.fd, VIDIOC_ENUMINPUT, &self.input_info):
            warnings.warn('Getting camera info failed')

        memset(&self.input_capabilities, 0, sizeof(self.input_capabilities))
        if -1 == xioctl(self.fd, VIDIOC_QUERYCAP, &self.input_capabilities):
            warnings.warn('Getting camera capabilities failed')

        # ----------------------------------------------------------------
        # Enumerate formats the hardware actually supports
        # ----------------------------------------------------------------
        memset(&fmtdesc, 0, sizeof(fmtdesc))
        fmtdesc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE
        pixel_formats = []
        fmtdesc.index = 0
        while xioctl(self.fd, VIDIOC_ENUM_FMT, &fmtdesc) == 0:
            pixel_formats.append(fmtdesc.pixelformat)
            fmtdesc.index += 1

        if not pixel_formats:
            v4l2_close(self.fd)
            raise CameraError('Could not enumerate camera formats')

        # ----------------------------------------------------------------
        # Select source format
        # ----------------------------------------------------------------
        memset(&self.fmt, 0, sizeof(self.fmt))
        self.fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE
        if -1 == xioctl(self.fd, VIDIOC_G_FMT, &self.fmt):
            v4l2_close(self.fd)
            raise CameraError('Getting format failed')

        if width and height:
            self.fmt.fmt.pix.width  = width
            self.fmt.fmt.pix.height = height

        if src_fmt is not None:
            if not isinstance(src_fmt, str) or len(src_fmt) != 4:
                v4l2_close(self.fd)
                raise ValueError("src_fmt must be a 4-character FourCC string e.g. 'MJPG', 'YUYV'")
            src_pixelformat = <unsigned int>v4l2_fourcc(
                ord(src_fmt[0]), ord(src_fmt[1]),
                ord(src_fmt[2]), ord(src_fmt[3]))
            if src_pixelformat not in pixel_formats:
                v4l2_close(self.fd)
                raise CameraError("Source format '{}' not supported by camera".format(src_fmt))
            self.fmt.fmt.pix.pixelformat = src_pixelformat
            if -1 == xioctl(self.fd, VIDIOC_S_FMT, &self.fmt):
                v4l2_close(self.fd)
                raise CameraError("Failed to set source format: {}".format(src_fmt))
        else:
            # Prefer compressed/native formats; libv4lconvert handles the rest
            preferred = [
                (V4L2_PIX_FMT_MJPEG,  "MJPG"),
                (V4L2_PIX_FMT_YUYV,   "YUYV"),
                (V4L2_PIX_FMT_YVYU,   "YVYU"),
                (V4L2_PIX_FMT_UYVY,   "UYVY"),
                (V4L2_PIX_FMT_YUV420, "YU12"),
                (V4L2_PIX_FMT_RGB24,  "RGB3"),
                (V4L2_PIX_FMT_BGR24,  "BGR3"),
            ]
            format_set = False
            for fmt_id, fmt_name in preferred:
                if fmt_id in pixel_formats:
                    self.fmt.fmt.pix.pixelformat = fmt_id
                    if xioctl(self.fd, VIDIOC_S_FMT, &self.fmt) == 0:
                        format_set = True
                        break
            if not format_set:
                # Last resort: whatever the camera gave us from G_FMT
                if -1 == xioctl(self.fd, VIDIOC_S_FMT, &self.fmt):
                    v4l2_close(self.fd)
                    raise CameraError('No supported source format found and fallback S_FMT failed')

        # Driver may adjust width/height — read back what was actually set
        self.width  = self.fmt.fmt.pix.width
        self.height = self.fmt.fmt.pix.height

        # Record source FourCC as string
        cdef unsigned int spf = self.fmt.fmt.pix.pixelformat
        self.src_pixel_format = chr(spf & 0xFF) + chr((spf >> 8) & 0xFF) + \
                                chr((spf >> 16) & 0xFF) + chr((spf >> 24) & 0xFF)

        # ----------------------------------------------------------------
        # Destination format and conversion setup
        # ----------------------------------------------------------------
        self.convert_data = v4lconvert_create(self.fd)
        if self.convert_data == NULL:
            v4l2_close(self.fd)
            raise CameraError('Failed to create v4lconvert context')

        if dest_fmt is not None:
            if not isinstance(dest_fmt, str) or len(dest_fmt) != 4:
                v4lconvert_destroy(self.convert_data)
                v4l2_close(self.fd)
                raise ValueError("dest_fmt must be a 4-character FourCC string e.g. 'RGB3', 'BGR3'")
            dst_pixelformat = <unsigned int>v4l2_fourcc(
                ord(dest_fmt[0]), ord(dest_fmt[1]),
                ord(dest_fmt[2]), ord(dest_fmt[3]))
            if not v4lconvert_supported_dst_format(dst_pixelformat):
                v4lconvert_destroy(self.convert_data)
                v4l2_close(self.fd)
                raise CameraError("dest_fmt '{}' not supported by libv4lconvert".format(dest_fmt))

            memset(&self.dst_fmt, 0, sizeof(self.dst_fmt))
            self.dst_fmt.type                = V4L2_BUF_TYPE_VIDEO_CAPTURE
            self.dst_fmt.fmt.pix.width       = self.width
            self.dst_fmt.fmt.pix.height      = self.height
            self.dst_fmt.fmt.pix.pixelformat = dst_pixelformat

            self.do_convert       = True
            self.dest_pixel_format = dest_fmt
            # Converted output is always packed 3-byte-per-pixel (RGB3/BGR3/etc.)
            self.conv_dest_size   = self.width * self.height * 3
        else:
            # Raw passthrough — output exactly what the camera gives us
            self.do_convert        = False
            self.dest_pixel_format = self.src_pixel_format
            raw_size = self.fmt.fmt.pix.sizeimage
            if raw_size == 0:
                raw_size = self.width * self.height * 2  # safe upper bound for packed YUV
            self.conv_dest_size = raw_size

        self.conv_dest = <unsigned char *>malloc(self.conv_dest_size)
        if self.conv_dest == NULL:
            v4lconvert_destroy(self.convert_data)
            v4l2_close(self.fd)
            raise CameraError('Allocating output buffer failed')

        # ----------------------------------------------------------------
        # Capture buffers
        # ----------------------------------------------------------------
        memset(&self.buf_req, 0, sizeof(self.buf_req))
        self.buf_req.count  = 4
        self.buf_req.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE
        self.buf_req.memory = V4L2_MEMORY_MMAP

        if -1 == xioctl(self.fd, VIDIOC_REQBUFS, &self.buf_req):
            free(self.conv_dest)
            v4lconvert_destroy(self.convert_data)
            v4l2_close(self.fd)
            raise CameraError('Requesting buffer failed')

        self.buffers = <buffer_info *>calloc(self.buf_req.count, sizeof(self.buffers[0]))
        if self.buffers == NULL:
            free(self.conv_dest)
            v4lconvert_destroy(self.convert_data)
            v4l2_close(self.fd)
            raise CameraError('Allocating buffer array failed')

        self.initialize_buffers()

        if -1 == xioctl(self.fd, VIDIOC_STREAMON, &self.buf.type):
            free(self.buffers)
            free(self.conv_dest)
            v4lconvert_destroy(self.convert_data)
            v4l2_close(self.fd)
            raise CameraError('Starting capture failed')

    cdef inline int initialize_buffers(self) except -1:
        cdef int buf_index
        cdef void *bufptr

        for buf_index in range(self.buf_req.count):
            memset(&self.buf, 0, sizeof(self.buf))
            self.buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE
            self.buf.memory = V4L2_MEMORY_MMAP
            self.buf.index  = buf_index

            if -1 == xioctl(self.fd, VIDIOC_QUERYBUF, &self.buf):
                raise CameraError('Querying buffer failed')

            bufptr = v4l2_mmap(NULL, self.buf.length,
                               PROT_READ | PROT_WRITE,
                               MAP_SHARED, self.fd, self.buf.m.offset)
            if bufptr == <void *>-1:
                raise CameraError('MMAP failed: {}'.format(strerror(errno).decode()))

            self.buffers[buf_index] = buffer_info(bufptr, self.buf.length)

            memset(&self.buf, 0, sizeof(self.buf))
            self.buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE
            self.buf.memory = V4L2_MEMORY_MMAP
            self.buf.index  = buf_index

            if -1 == xioctl(self.fd, VIDIOC_QBUF, &self.buf):
                raise CameraError('Queuing buffer failed')

        return 0

    cdef list enumerate_menu(self, v4l2_queryctrl *queryctrl,
                              v4l2_querymenu *querymenu):
        menu = []
        if queryctrl.type == V4L2_CTRL_TYPE_MENU:
            memset(querymenu, 0, sizeof(querymenu[0]))
            querymenu.id = queryctrl.id
            for querymenu.index in range(queryctrl.minimum, queryctrl.maximum + 1):
                if 0 == xioctl(self.fd, VIDIOC_QUERYMENU, querymenu):
                    menu.append(querymenu.name.decode('utf-8'))
                else:
                    raise CameraError('Querying controls failed')
        return menu

    cpdef list get_controls(self):
        cdef v4l2_queryctrl queryctrl
        cdef v4l2_querymenu querymenu
        controls_list = []

        memset(&queryctrl, 0, sizeof(queryctrl))
        for queryctrl.id in range(V4L2_CID_BASE, V4L2_CID_LASTP1):
            if 0 == xioctl(self.fd, VIDIOC_QUERYCTRL, &queryctrl):
                if queryctrl.flags & V4L2_CTRL_FLAG_DISABLED:
                    continue
                controls_list.append(
                    CameraControl(queryctrl.id, queryctrl.type,
                                  queryctrl.name.decode('utf-8'),
                                  queryctrl.default_value, queryctrl.minimum,
                                  queryctrl.maximum, queryctrl.step,
                                  self.enumerate_menu(&queryctrl, &querymenu),
                                  queryctrl.flags))
            elif errno == EINVAL:
                continue
            else:
                raise CameraError('Querying controls failed')

        queryctrl.id = V4L2_CID_PRIVATE_BASE
        while True:
            if 0 == xioctl(self.fd, VIDIOC_QUERYCTRL, &queryctrl):
                if queryctrl.flags & V4L2_CTRL_FLAG_DISABLED:
                    continue
                controls_list.append(
                    CameraControl(queryctrl.id, queryctrl.type,
                                  queryctrl.name.decode('utf-8'),
                                  queryctrl.default_value, queryctrl.minimum,
                                  queryctrl.maximum, queryctrl.step,
                                  self.enumerate_menu(&queryctrl, &querymenu),
                                  queryctrl.flags))
            elif errno == EINVAL:
                break
            else:
                raise CameraError('Querying controls failed')

        return controls_list

    cpdef void set_control_value(self, control_id, value):
        cdef v4l2_queryctrl queryctrl
        cdef v4l2_control control

        memset(&queryctrl, 0, sizeof(queryctrl))
        queryctrl.id = control_id.value
        if -1 == xioctl(self.fd, VIDIOC_QUERYCTRL, &queryctrl):
            if errno != EINVAL:
                raise CameraError('Querying control')
            else:
                raise AttributeError('Control is not supported')
        elif queryctrl.flags & V4L2_CTRL_FLAG_DISABLED:
            raise AttributeError('Control is not supported')
        else:
            memset(&control, 0, sizeof(control))
            control.id    = control_id.value
            control.value = value
            if -1 == xioctl(self.fd, VIDIOC_S_CTRL, &control):
                raise CameraError('Setting control')

    cpdef int get_control_value(self, control_id):
        cdef v4l2_queryctrl queryctrl
        cdef v4l2_control control

        memset(&queryctrl, 0, sizeof(queryctrl))
        queryctrl.id = control_id.value
        if -1 == xioctl(self.fd, VIDIOC_QUERYCTRL, &queryctrl):
            if errno != EINVAL:
                raise CameraError('Querying control')
            else:
                raise AttributeError('Control is not supported')
        elif queryctrl.flags & V4L2_CTRL_FLAG_DISABLED:
            raise AttributeError('Control is not supported')
        else:
            memset(&control, 0, sizeof(control))
            control.id = control_id.value
            if 0 == xioctl(self.fd, VIDIOC_G_CTRL, &control):
                return control.value
            else:
                raise CameraError('Getting control')

    cpdef bytes get_frame(self):
        cdef unsigned int nbytes

        FD_ZERO(&self.fds)
        FD_SET(self.fd, &self.fds)
        self.tv.tv_sec = 2

        r = select(self.fd + 1, &self.fds, NULL, NULL, &self.tv)
        while -1 == r and errno == EINTR:
            FD_ZERO(&self.fds)
            FD_SET(self.fd, &self.fds)
            self.tv.tv_sec = 2
            r = select(self.fd + 1, &self.fds, NULL, NULL, &self.tv)

        if -1 == r:
            raise CameraError('Waiting for frame failed')

        memset(&self.buf, 0, sizeof(self.buf))
        self.buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE
        self.buf.memory = V4L2_MEMORY_MMAP

        if -1 == xioctl(self.fd, VIDIOC_DQBUF, &self.buf):
            raise CameraError('Retrieving frame failed')

        # Save before QBUF — some drivers clear bytesused on requeue
        nbytes = self.buf.bytesused

        if self.do_convert:
            if -1 == v4lconvert_convert(
                    self.convert_data,
                    &self.fmt, &self.dst_fmt,
                    <unsigned char *>self.buffers[self.buf.index].start,
                    nbytes,
                    self.conv_dest,
                    self.conv_dest_size):
                xioctl(self.fd, VIDIOC_QBUF, &self.buf)  # requeue before raising
                raise CameraError('Conversion failed')
        else:
            if nbytes > self.conv_dest_size:
                nbytes = self.conv_dest_size
            memcpy(self.conv_dest,
                   <unsigned char *>self.buffers[self.buf.index].start,
                   nbytes)

        if -1 == xioctl(self.fd, VIDIOC_QBUF, &self.buf):
            raise CameraError('Requeuing buffer failed')

        if self.do_convert:
            return self.conv_dest[:self.conv_dest_size]
        else:
            return self.conv_dest[:nbytes]

    def close(self):
        xioctl(self.fd, VIDIOC_STREAMOFF, &self.buf.type)
        for i in range(self.buf_req.count):
            v4l2_munmap(self.buffers[i].start, self.buffers[i].length)
        free(self.buffers)
        free(self.conv_dest)
        v4lconvert_destroy(self.convert_data)
        v4l2_close(self.fd)