import numpy as np
import cv2
import sys
import time

sys.path = reversed(sys.path)  # search global packages first. python can't import local cython without building.

from PyV4L2Cam.camera import Camera
from PyV4L2Cam.controls import ControlIDs

camera = Camera('/dev/video0', 99999, 99999)
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
        i = cv2.imdecode(np.fromstring(jpg, dtype=np.uint8), cv2.IMREAD_COLOR)
        cv2.imshow('i', i)
        t1 = time.time()
        print(f'{(t1 - t0) * 1000}FPS')
        t0 = t1
        if cv2.waitKey(1) == 27:
            break

camera.close()
