import numpy as np
import cv2
import sys
import time
import typing
sys.path = reversed(sys.path)  # search global packages first. python can't import local cython without building.

from PyV4L2Cam.camera import Camera
from PyV4L2Cam.controls import ControlIDs

cams = []

for i in range(100):
    try:
        cam = Camera(f'/dev/video{i}', 1, 1)
        print(f"/dev/video{i}")
        print("-----------------")
        for a,b in cam.input_capabilities.items():
            print(f'{a}:{b}')
        print("----------------")
        cams.append(cam)
    except Exception as e:
        pass
camera = cams[0]

controls = camera.get_controls()

for control in controls:
    print(control.name)

camera.set_control_value(ControlIDs.BRIGHTNESS, 0)
t0 = t1 = time.time()
for _ in range(100000000):
    frame_bytes = camera.get_frame()

    # Decode the image
    # Thanks: https://stackoverflow.com/a/21844162
    a = frame_bytes.find(b'\xff\xd8')
    b = frame_bytes.find(b'\xff\xd9')
    if a != -1 and b != -1:
        jpg = frame_bytes[a:b + 2]
        bytes = frame_bytes[b + 2:]
        i = cv2.imdecode(np.frombuffer(jpg, dtype=np.uint8), cv2.IMREAD_COLOR)
        cv2.imshow('i', i)
        t1 = time.time()
        print(f'{(1.0/(t1 - t0))}FPS')
        t0 = t1
        if cv2.waitKey(1) == 27:
            break

camera.close()
