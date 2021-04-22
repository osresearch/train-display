![Indoor LED display component side](images/indoor-pcb.jpg)

Row/Column with shift registers and row-decode to MOSFET.
Triple scan (three rows on at a time), although the bottom quarter
of the display is not populated.

* 24x [TB62706](datasheets/TB62706.pdf) - 16-bit shift register (
* 16x [NTD20NO3L27](datasheets/NTD20N03L27-D.PDF) - N-Channel MOSFET (low-side row switch)
* 1x [74HCT244](datasheets/74HC_HCT244.pdf) - Octal buffer (clock fanout)
* 1x [HEF4514BT](datasheets/HEF4514BT.pdf) - 4-to-16 line decoder (row select)
