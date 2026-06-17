# LUKS Container Autosetup Script

Version 1.2

# PURPOSE

This bash script is designed to simplify the creation of compatible LUKS containers via cryptsetup. Setting up encrypted images was always a cumbersome process with a lot of typing, so this scripts aims to make it easier for the user especially in terminal-only environments. Only LUKS file containers / images are created by this script. Block devices (partitions) are NOT supported. Script works with multiple LUKS file containers.

# SYSTEM REQUIREMENTS

The only requirements are systems with hardware to support modern encryption and decryption, cryptsetup and associated packages, and running in a debian-based environment (ubuntu, mint, popOS, debian etc.)

# INSTALLATION

Make executable and run:

    chmod +x /luks-container-autosetup-script-v1.x.sh
    ./luks-container-autosetup-script-v1.x.sh

# DISCLAIMER
Please review this bash script carefully. NEVER run a script blindly without understanding what it could do. Don't trust me. Google around to find out more. Please research, research, research.

# LEGAL
Please note that by downloading and running this script you acknowledge that I am not responsible or liable for any damages or losses arising from your use or inability to use the script and or software used under this script. You are solely responsible for your use of this script. If you harm someone or get into a dispute with a 3rd party, you consent to me waiving any involvement.
