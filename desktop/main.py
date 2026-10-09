import os
import socket
import struct
import sys
import time

import cv2
import numpy as np
from PyQt5.QtCore import Qt, QThread, pyqtSignal
from PyQt5.QtGui import QIcon, QImage, QPixmap
from PyQt5.QtWidgets import (QApplication, QComboBox, QFrame, QHBoxLayout, QLabel,
                             QMainWindow, QVBoxLayout, QWidget)

import usbmux

PORT = 9999
RESOLUTIONS = [("Native (as sent by iPhone)", None),
               ("3840x2160  (4K UHD)", (3840, 2160)),
               ("2560x1440  (QHD)", (2560, 1440)),
               ("1920x1080  (FHD)", (1920, 1080))]


def resource_path(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


class StreamWorker(QThread):
    status = pyqtSignal(str, str)      # text, state: wait | live | error
    stats = pyqtSignal(str)
    preview = pyqtSignal(QImage)

    def __init__(self):
        super().__init__()
        self._running = True
        self.target = None             # None = native, or (w, h)

    def stop(self):
        self._running = False

    # -- main loop: find phone -> open tunnel -> stream -> repeat
    def run(self):
        while self._running:
            try:
                devices = usbmux.list_usb_devices()
            except OSError:
                self.status.emit("Apple USB driver not found - install iTunes or Apple Devices", "error")
                self._sleep(2)
                continue
            if not devices:
                self.status.emit("Connect your iPhone with a USB cable", "wait")
                self._sleep(1.5)
                continue
            try:
                sock = usbmux.connect(devices[0], PORT)
            except (usbmux.UsbmuxError, OSError):
                self.status.emit("Open the USC-CAM app on your iPhone (and tap Trust)", "wait")
                self._sleep(1.5)
                continue
            try:
                self._stream(sock)
            except (OSError, ConnectionError, struct.error):
                pass
            finally:
                sock.close()
            self.stats.emit("")

    def _sleep(self, seconds):
        end = time.time() + seconds
        while self._running and time.time() < end:
            time.sleep(0.05)

    def _stream(self, sock):
        import pyvirtualcam
        cam = None
        cam_size = None
        frames = 0
        tick = time.time()
        n = 0
        try:
            while self._running:
                size = struct.unpack(">I", usbmux.recv_exact(sock, 4))[0]
                if size == 0 or size > 64 * 1024 * 1024:
                    raise ConnectionError("bad frame header")
                data = usbmux.recv_exact(sock, size)
                frame = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
                if frame is None:
                    continue

                target = self.target
                if target and (frame.shape[1], frame.shape[0]) != target:
                    frame = cv2.resize(frame, target, interpolation=cv2.INTER_AREA)
                h, w = frame.shape[:2]

                if cam is None or cam_size != (w, h):
                    if cam is not None:
                        cam.close()
                    try:
                        cam = pyvirtualcam.Camera(width=w, height=h, fps=30,
                                                  fmt=pyvirtualcam.PixelFormat.BGR)
                    except Exception:
                        self.status.emit("Install OBS Studio once (it provides the virtual camera driver)", "error")
                        raise ConnectionError("no virtual camera")
                    cam_size = (w, h)
                    self.status.emit("LIVE  -  select 'OBS Virtual Camera' in your app", "live")

                cam.send(frame)

                frames += 1
                n += 1
                if n % 4 == 0:
                    small = cv2.resize(frame, (480, int(480 * h / w)), interpolation=cv2.INTER_AREA)
                    rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
                    img = QImage(rgb.data, rgb.shape[1], rgb.shape[0], rgb.strides[0],
                                 QImage.Format_RGB888).copy()
                    self.preview.emit(img)
                now = time.time()
                if now - tick >= 1:
                    self.stats.emit("%dx%d  -  %d fps" % (w, h, round(frames / (now - tick))))
                    frames, tick = 0, now
        finally:
            if cam is not None:
                cam.close()


class MainWindow(QMainWindow):
    COLORS = {"wait": "#E8A33D", "live": "#3DDC84", "error": "#FF5A5A"}

    def __init__(self):
        super().__init__()
        self.setWindowTitle("USC-CAM")
        self.setFixedSize(520, 600)
        icon_file = resource_path("icon.ico")
        if os.path.exists(icon_file):
            self.setWindowIcon(QIcon(icon_file))
        self.setStyleSheet("""
            QMainWindow { background-color: #0A0A0A; }
            QLabel { color: #FFFFFF; font-family: 'Segoe UI', sans-serif; }
            QLabel#Title { font-size: 26px; font-weight: bold; letter-spacing: 4px; }
            QLabel#Sub { font-size: 11px; color: #888888; font-weight: 600; letter-spacing: 3px; }
            QLabel#Stats { font-size: 13px; color: #BBBBBB; }
            QFrame#Pill { background-color: #1A1A1A; border-radius: 18px; }
            QLabel#Preview { background-color: #000000; border: 1px solid #262626; border-radius: 10px; }
            QComboBox { background-color: #1A1A1A; color: #FFFFFF; border: 1px solid #333333;
                        border-radius: 8px; padding: 10px 14px; font-size: 14px; font-weight: 600; }
            QComboBox::drop-down { border: none; }
            QComboBox QAbstractItemView { background-color: #1A1A1A; color: #FFFFFF;
                        selection-background-color: #333333; border: 1px solid #333333; }
        """)

        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(24, 24, 24, 24)
        root.setSpacing(14)

        title = QLabel("USC-CAM")
        title.setObjectName("Title")
        title.setAlignment(Qt.AlignCenter)
        sub = QLabel("USB WEBCAM  -  4K")
        sub.setObjectName("Sub")
        sub.setAlignment(Qt.AlignCenter)
        root.addWidget(title)
        root.addWidget(sub)

        self.preview = QLabel("No video yet")
        self.preview.setObjectName("Preview")
        self.preview.setAlignment(Qt.AlignCenter)
        self.preview.setFixedHeight(270)
        self.preview.setStyleSheet(self.preview.styleSheet())
        root.addWidget(self.preview)

        pill = QFrame()
        pill.setObjectName("Pill")
        pl = QHBoxLayout(pill)
        pl.setContentsMargins(16, 10, 16, 10)
        self.dot = QLabel("●")
        self.status = QLabel("Starting...")
        self.status.setStyleSheet("font-size: 13px; font-weight: 600;")
        pl.addWidget(self.dot)
        pl.addWidget(self.status, 1)
        root.addWidget(pill)

        self.stats = QLabel("")
        self.stats.setObjectName("Stats")
        self.stats.setAlignment(Qt.AlignCenter)
        root.addWidget(self.stats)

        self.res = QComboBox()
        for label, _ in RESOLUTIONS:
            self.res.addItem(label)
        self.res.currentIndexChanged.connect(self.on_res)
        root.addWidget(self.res)
        root.addStretch(1)
        self.setCentralWidget(central)

        self.set_status("Starting...", "wait")
        self.worker = StreamWorker()
        self.worker.status.connect(self.set_status)
        self.worker.stats.connect(self.stats.setText)
        self.worker.preview.connect(self.set_preview)
        self.worker.start()

    def on_res(self, i):
        self.worker.target = RESOLUTIONS[i][1]

    def set_status(self, text, state):
        self.status.setText(text)
        self.dot.setStyleSheet("color: %s; font-size: 14px;" % self.COLORS.get(state, "#888"))
        if state != "live":
            self.preview.setPixmap(QPixmap())
            self.preview.setText("No video yet")

    def set_preview(self, img):
        pm = QPixmap.fromImage(img).scaled(self.preview.width() - 4, self.preview.height() - 4,
                                           Qt.KeepAspectRatio, Qt.SmoothTransformation)
        self.preview.setPixmap(pm)

    def closeEvent(self, event):
        self.worker.stop()
        self.worker.wait(2000)
        event.accept()


if __name__ == "__main__":
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    w = MainWindow()
    w.show()
    sys.exit(app.exec_())
