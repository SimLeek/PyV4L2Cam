from typing import Optional
import numpy as np
import cv2


def convert_mjpeg(mjpeg: bytes) -> Optional[np.ndarray]:
    # Thanks: https://stackoverflow.com/a/21844162
    a = mjpeg.find(b"\xff\xd8")
    b = mjpeg.find(b"\xff\xd9")

    if a == -1 or b == -1:
        return None
    else:
        jpg = mjpeg[a: b + 2]
        frame = cv2.imdecode(np.frombuffer(jpg, dtype=np.uint8), cv2.IMREAD_COLOR)
        return frame


def convert_rgb24(rgb24: bytes, width: int, height: int) -> Optional[np.ndarray]:
    nparr = np.frombuffer(rgb24, np.uint8)
    np_frame = nparr.reshape((height, width, 3))
    return np_frame
