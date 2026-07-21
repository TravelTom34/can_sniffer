# M2 BHM CAN Sniffer — Field Reference (R4 + MCP2515, Kali/Linux)


!!!!!  Easy Way to Work with the tool is run the install.sh script, it does all this below for you.


## Every-session workflow (in order)

### 1. Check what device the R4 landed on
ls -l /dev/ttyACM*
# Numbers shift every time you unplug/replug — don't assume ACM0

### 2. Tear down any leftover slcand session before flashing or reconnecting
sudo ip link set can0 down
sudo pkill slcand
sudo fuser /dev/ttyACM0      # confirm free — swap in whatever ACM number is active

### 3. (Only if reflashing firmware) Upload from Arduino IDE now
# Board: Arduino Uno R4 WiFi
# Port: whatever /dev/ttyACM# showed up in step 1
# Be sure to release can0 inteface and bring it down so you can flash sketch to IDE

### 4. Attach the R4 as a real SocketCAN interface
sudo slcand -o -c -s5 -S 115200 /dev/ttyACM0 can0  // 250kbps
sudo slcand -o -c -s6 -S 115200 /dev/ttyACM0 can0  // 500kbps swap ACM number as needed
sudo ip link set up can0

### 5. Verify it's alive
ipa a


Here's the full slcand -s bitrate code table (this is the standard SLCAN/LAWICEL spec, same one your firmware's S command handler acknowledges but ignores):
Flag	Bitrate	Notes
-s0	10 kbps	
-s1	20 kbps	
-s2	50 kbps	
-s3	100 kbps	
-s4	125 kbps	
-s5	250 kbps	Your BHM body/cab bus
-s6	500 kbps	J1939 engine/chassis bus
-s7	800 kbps	
-s8	1000 kbps (1 Mbps)
