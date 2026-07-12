# LUKS Container Management Script

Version 4.1

# PURPOSE

This bash script is designed to simplify the creation and management of compatible LUKS containers via cryptsetup.

Setting up encrypted images was always a cumbersome process with lots of typing so this scripts aims to make LUKS management easier, especially in cli environments. There are many github scripts available for LUKS encrypted partitions but hardly any for encrypted images, hence this script was created for this very scenario.

So why use LUKS, when other well-supported file encryption software is available (like gpg or veracrypt)? Because it's a known, reliable, flexible, secure encryption standard with strong defaults. No need to worry about selecting 'The Best™️' encryption settings. Just create and forget about it. Plus multiple keys (and keyfiles) can be used.

Of course, the single most important security factor is the strength of the password so **USE A STRONG PASSWORD!**

Only LUKS file containers / images are created. Block devices (partitions) are **NOT supported**. This script works with multiple LUKS file containers.

# SYSTEM REQUIREMENTS

The only requirements are systems with hardware to support modern encryption and decryption, cryptsetup and associated packages, and running in a debian-based environment (ubuntu, mint, popOS, debian etc.)

# INSTALLATION

Make executable and run:

    chmod +x /luks-container-management-script-v4.x.sh
    ./luks-container-management-script-v4.x.sh

# IMPORTANT INFORMATION

1. Binary images use base-10 numbers. Final container size will be smaller when measured in GB. So creating a 1000 MB container will actually result in a final size of 0.97 GB (eg. 1 GB = 1024 MB). Take this into consideration when creating the target image size.

2. Resizing LUKS containers is inherently risky. Especially when truncating.

   **ALWAYS create a backup before proceeding with any changes!**

   When shrinking, a minimum size guide offers conservative, moderate and aggressive size suggestions. Please remember that these sizes are only approximations thus data corruption is likely when containers are truncated below the filesystem and close to the underlying existing data. And don't forget that filesystem fragmentation may require more space.

5. Keyfiles can be used in addition to (or as a replacement of) existing keys in the container. Since they act just like physical keys you need to be extra careful about storing them in a secure way. It is highly recommended to keep keyfiles completely offline (eg. a detached usb drive) and also create LUKS containers on a LiveCD/USB OS (RAM-only) for memory security.


# LUKS Default Parameters:
These default settings are completely fine for most users. As already mentioned, password strength is the most important security factor. Encryption parameters only matter when the password is weak!
- Cipher: aes-xts-plain64
- Key Size: 512 bits
- Header Hashing: sha256
- Passphrase Derivation: argon2id
- Random Number Generator: /dev/urandom 

https://www.strongdm.com/blog/nist-password-guidelines

# SCREENSHOTS

![First screen](Screenshot-1.png)
![Second screen](Screenshot-2.png)
![Third screen](Screenshot-3.png)
![Forth screen](Screenshot-4.png)
![Fifth screen](Screenshot-5.png)

# DISCLAIMER
Please review this bash script carefully. NEVER run a script blindly without understanding what it could do. Don't trust me. Google around to find out more. Please research, research, research.

# LEGAL
Please note that by downloading and running this script you acknowledge that I am not responsible or liable for any damages or losses arising from your use or inability to use the script and or software used under this script. You are solely responsible for your use of this script. If you harm someone or get into a dispute with a 3rd party, you consent to me waiving any involvement.
