; SPDX-FileCopyrightText: 2022 Zeal 8-bit Computer <contact@zeal8bit.com>
;
; SPDX-License-Identifier: Apache-2.0

    INCLUDE "errors_h.asm"
    INCLUDE "osconfig.asm"
    INCLUDE "mmu_h.asm"
    INCLUDE "drivers_h.asm"
    INCLUDE "vfs_h.asm"
    INCLUDE "disks_h.asm"
    INCLUDE "interrupt_h.asm"
    INCLUDE "i2c_h.asm"
    INCLUDE "log_h.asm"

    DEFC I2C_EEPROM_DISK_LETTER = 'B'
    DEFC I2C_EEPROM_ADDRESS = 0x50
    DEFC I2C_MAX_WRITE_SIZE = 64
    DEFC I2C_PAGE_BOUND_MASK = I2C_MAX_WRITE_SIZE - 1

    SECTION KERNEL_DRV_TEXT
eeprom_init:
    ; Before mounting the disk, make sure it is formatted. To do so, read the first two bytes.
    ; Re-use the same buffer for write and reads.
    ld hl, 0
    ld (_eeprom_buffer), hl
    ld hl, _eeprom_buffer
    ld d, h
    ld e, l
    ld bc, 0x0202 ; B and C set to 2
    ld a, I2C_EEPROM_ADDRESS
    call i2c_write_read_device
    or a
    ; If the device didn't reply, do not mount it (of course)
    jr nz, _eeprom_init_error
    ; Check the data read from the disk. The first byte should be 'Z', the second (version) should be 1
    ; FIXME: this check should be done by the file system?
    ld a, (de)
    cp 'Z'
    jr nz, _eeprom_init_error
    inc de
    ld a, (de)
    dec a
    jr nz, _eeprom_init_error
    ; The EEPROM is properly formatted, mount it as a disk
    ld a, I2C_EEPROM_DISK_LETTER
    ; Put the file system in E (rawtable)
    ld e, FS_ZEALFS
    ; Driver structure in HL
    ld hl, _eeprom_driver
    jp zos_disks_mount
_eeprom_init_error:
    ld hl, _error_message
    call zos_log_error
    ld a, ERR_FAILURE
    ret
_error_message: DEFM "EEPROM not connected or formatted\n", 0

    ; Open function, called every time a file is opened on this driver
    ; Note: This function should not attempt to check whether the file exists or not,
    ;       the filesystem will do it. Instead, it should perform any preparation
    ;       (if needed) as multiple reads will occur.
    ; Parameters:
    ;       BC - Name of the file to open
    ;       A  - Flags
    ; Returns:
    ;       A - ERR_SUCCESS if success, error code else
    ; Alters:
    ;       A, BC, DE, HL (any of them can be altered, caller-saved)
eeprom_open:
eeprom_close:
eeprom_deinit:
    ; Nothing special to do in this case, return success
    ld a, ERR_SUCCESS
    ret

    ; Read function, called every time the filesystem needs data from the rom disk.
    ; Parameters:
    ;       DE - Destination buffer.
    ;       BC - Size to read in bytes. Guaranteed to be equal to or smaller than 16KB.
    ;       Top of stack: 32-bit offset. MUST BE POPPED IN THIS FUNCTION.
    ;              [SP]   - Upper 16-bit of offset
    ;              [SP+2] - Lower 16-bit of offset
    ; Returns:
    ;       A  - ERR_SUCCESS if success, error code else
    ;       BC - Number of bytes read.
    ; Alters:
    ;       This function can alter any register.
eeprom_read:
    ; The offset must be 16-bit according to the filesystem, so the top of the stack must have
    ; 0x000
    pop hl
    ld a, h
    or l
    pop hl
    jr nz, eeprom_read_invalid_offset
    ; In practice, BC will also be smaller than 256 when called from the FS, so don't accept
    ; bigger size for now.
    or b
    jr nz, eeprom_read_invalid_size
    push bc
    ; We must store the offset in big-endian in a buffer
    ld a, h
    ld h, l
    ld l, a
    ld (_eeprom_buffer), hl
    ld hl, _eeprom_buffer
    ; Perform the I2C request now
    ld a, I2C_EEPROM_ADDRESS
    ld b, 2 ; 16-bit offset
    call i2c_write_read_device
    pop bc
    ret
eeprom_read_invalid_size:
    ld a, ERR_INVALID_PARAMETER
    ret
eeprom_read_invalid_offset:
    ld a, ERR_INVALID_OFFSET
    ret


    ; API: Same as the routine above but for writing.
eeprom_write:
    ; The offset must be 16-bit according to the filesystem, so the top of the stack must have
    ; 0x000
    pop hl
    ld a, h
    or l
    pop hl
    jr nz, eeprom_read_invalid_offset
    or b
    jr nz, eeprom_read_invalid_size
    push bc
    ; We can only write I2C_MAX_WRITE_SIZE at once on I2C EEPROMs. Thus,
    ; we have to iterate until BC is 0. Moreover, we cannot cross page boundary.
    ; L contains the offset in the current I2C page, calculate the minimum between
    ; I2C_MAX_WRITE_SIZE - (L & (I2C_MAX_WRITE_SIZE - 1)) and C
_eeprom_write_loop:
    ld a, I2C_MAX_WRITE_SIZE - 1
    ; A = Offset of HL in the current page (HL % I2C_MAX_WRITE_SIZE)
    and l
    ; A = PAGE_SIZE - Offset
    neg
    add I2C_MAX_WRITE_SIZE
    ; A contains the maximum amount of bytes we can write in the current I2C page
    ; Compare it to C
    cp c
    jr c, _eeprom_write_loop_write_a
    ; C is smaller or equal to A, so write C bytes
    ld a, c
_eeprom_write_loop_write_a:
    ; Now, let's write A bytes from DE to offset HL
    ld b, a     ; save the bytes we are going to write in A
    push bc     ; preserve the remaining size
    call _eeprom_write_page
    pop bc
    or a
    jr nz, _eeprom_failure
    ; Calculate the remaining size, in other words, C = C - B
    ld a, c
    sub b
    ld c, a
    jp nz, _eeprom_write_loop
_eeprom_write_loop_end:
    ; Success, we can return BC
    pop bc
    xor a
    ret
_eeprom_failure:
    pop bc
    ld a, ERR_FAILURE
    ret

    ; Parameters:
    ;   B - Number of bytes to write
    ;   HL - Offset to write byte to
    ;   DE - Bytes to write
    ; Returns:
    ;   A : success or error code
    ;   HL : HL += B
    ;   DE : DE += B
    ; Alters:
    ;   A, BC
_eeprom_write_page:
    ; We must store the offset in big-endian in a buffer
    push hl
    push de
    push bc
    ld a, l
    ld (_eeprom_buffer + 1), a
    ld a, h
    ld hl, _eeprom_buffer
    ld (hl), a
    ;   A - 7-bit device address
    ;   DE - Register address buffer
    ;   C  - Size of the register address buffer, can be 0, which ignores DE
    ;   HL - Buffer to write on the bus
    ;   B - Size of the buffer, must not be 0
    ld a, I2C_EEPROM_ADDRESS
    ex de, hl
    ld c, 2
    call i2c_write_double_buffer
    or a
    ; If the transfer was a success, we have to wait for the write to finish
    call z, eeprom_write_poll
    pop bc
    pop de
    pop hl
    ; HL += B
    ld c, b
    ld b, 0
    add hl, bc
    ; DE += B
    ex de, hl
    add hl, bc
    ex de, hl
    ret

    ; After a write, the EEPROM will stop responding until the write is
    ; done internally. We have to poll the device until is responds again.
    ; Returns:
    ;   A - Success
    ; Alters:
    ;   A, BC, DE, HL
eeprom_write_poll:
    ; Read a dummy byte from the device, only to see if it responds
    ; Parameters:
    ;   A - 7-bit device address
    ;   HL - Buffer to store the bytes read
    ;   B - Size of the buffer
    ld b, 1
_eeprom_write_poll_loop:
    ld a, I2C_EEPROM_ADDRESS
    ld hl, _eeprom_buffer
    call i2c_read_device
    or a
    jr nz, _eeprom_write_poll_loop
    ret

eeprom_seek:
    ; Seek shouldn't be called as it should be implemented by the filesystem.
eeprom_ioctl:
    ld a, ERR_NOT_IMPLEMENTED
    ret

    SECTION KERNEL_BSS
_eeprom_buffer: DEFS 2

    SECTION KERNEL_DRV_VECTORS
_eeprom_driver:
NEW_DRIVER_STRUCT("DSK1", \
                  eeprom_init, \
                  eeprom_read, eeprom_write, \
                  eeprom_open, eeprom_close, \
                  eeprom_seek, eeprom_ioctl, \
                  eeprom_deinit)