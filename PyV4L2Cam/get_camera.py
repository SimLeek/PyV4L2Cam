from pathlib import Path
from PyV4L2Cam.camera import Camera, CameraError


def get_camera_by_bus_info(bus_info, width=1, height=1, partial_match=True):
    p = Path('/dev/')
    files = p.glob('video*')
    if isinstance(bus_info, str):
        bus_info_bytes = bytes(bus_info, encoding='utf-8')
    else:
        bus_info_bytes = bus_info
    for f in files:
        try:
            cam = Camera(str(f), width, height)
            if (partial_match and bus_info_bytes in cam.input_capabilities['bus_info']) or \
                    (bus_info_bytes == cam.input_capabilities['bus_info']):
                return cam
            else:
                cam.close()
        except CameraError as ce:
            pass


def get_bus_info_from_camera(cam):
    return cam.input_capabilities['bus_info']


def get_camera_by_string(cam_str: str, width=1, height=1, ):
    if cam_str.isdigit() or isinstance(cam_str, int):
        return Camera(f'/dev/video{cam_str}', width, height)
    else:
        return Camera(cam_str, width, height)
