# InkgloWavesER_QsysPlugin
Q-SYS Designer plugin for controlling the InkgloWaves ER Series IoT Smart Relay Node

The InkgloWaves ER Q-SYS Plugin allows Q-SYS systems to communicate directly with the InkgloWaves ER IoT Smart Relay Node using HTTP-based RESTful commands.
It provides network control of all relays, feedback status monitoring, and integration of authentication and grouping features directly within Q-SYS Designer.

This plugin is designed for integrators who need secure, real-time control of ER devices within a Q-SYS environment enabling automation, sequencing, or device power management from the Q-SYS ecosystem.


Features
- Control of all ER relays via RESTful HTTP requests.
- Support for “Toggle All” and group control.
- Real-time feedback of relay states and device connection.
- Configuration for:
      - Device IP address
      - Port number
      - Authentication credentials (Digest Auth)
- User interface components for each relay (toggle buttons + indicators).
- Compatible with ER firmware v1.0 (REST API).
- Status monitor for network and authentication errors.
