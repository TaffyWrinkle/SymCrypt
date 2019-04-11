;
;  AesAsm.asm   Assembler code for fast AES on the x86
;
; Copyright (c) Microsoft Corporation.  All rights reserved.
;
; This code is derived from the AesFast implemenation that
; Niels Ferguson wrote from scratch for BitLocker during Vista.
; That code is still in RSA32.
;



        TITLE   "Advanced Encryption Standard (AES)"
        .586P
        .XMM

;
; FPO documentation:
; The .FPO provides debugging information.
; This stuff not well documented, 
; but here is the information I've gathered about the arguments to .FPO
; 
; In order:
; cdwLocals: Size of local variables, in DWords
; cdwParams: Size of parameters, in DWords. Given that this is all about
;            stack stuff, I'm assuming this is only about parameters passed
;            on the stack.
; cbProlog : Number of bytes in the prolog code. We have interleaved the
;            prolog code with work for better performance. Most uses of
;            .FPO seem to set this value to 0 anyway, which is what we
;            will do.
; cbRegs   : # registers saved in the prolog. 
; fUseBP   : 0 if EBP is not used as base pointer, 1 if EBP is used as base pointer
; cbFrame  : Type of frame.
;            0 = FPO frame (no frame pointer)
;            1 = Trap frame (result of a CPU trap event)
;            2 = TSS frame
;
; Having looked at various occurrences of .FPO in the Windows code it
; seems to be used fairly sloppy, with lots of arguments left 0 even when
; they probably shouldn't be according to the spec.
;



_TEXT   SEGMENT PARA PUBLIC USE32 'CODE'
        ASSUME  CS:_TEXT, DS:FLAT, SS:FLAT

include <..\inc\symcrypt_version.inc>
include symcrypt_magic.inc


;
; Structure definition that mirrors the SYMCRYPT_AES_EXPANDED_KEY structure.
;

N_ROUND_KEYS_IN_AESKEY    EQU     29        

SYMCRYPT_AES_EXPANDED_KEY struct
        RoundKey        db      16*N_ROUND_KEYS_IN_AESKEY dup (?)
        lastEncRoundKey dd      ?
        lastDecRoundKey dd      ?

        SYMCRYPT_MAGIC_FIELD
        
SYMCRYPT_AES_EXPANDED_KEY ends



        PUBLIC  @SymCryptAesEncryptAsm@12
;        PUBLIC  @SymCryptAesEncryptXmm@12
        
        PUBLIC  @SymCryptAesDecryptAsm@12
;        PUBLIC  @SymCryptAesDecryptXmm@12
        
        PUBLIC  @SymCryptAesCbcEncryptAsm@20
;        PUBLIC  @SymCryptAesCbcEncryptXmm@20
        
        PUBLIC  @SymCryptAesCbcDecryptAsm@20
        ;PUBLIC  @SymCryptAesCbcDecryptXmm@20
        
        ;PUBLIC @SymCryptAesCbcMacAsm@16
        PUBLIC @SymCryptAesCtrMsb64Asm@20
        
        ;PUBLIC  @SymCryptAes4SboxXmm@8
        ;PUBLIC  @SymCryptAesCreateDecryptionRoundKeyXmm@8

;        PUBLIC  @SymCryptAesEncryptAsmInternal@16       ; Not needed, but makes debugging easier
;        PUBLIC  @SymCryptAesDecryptAsmInternal@16       ; Not needed, but makes debugging easier
        
        EXTRN   _SymCryptAesSboxMatrixMult:DWORD
        EXTRN   _SymCryptAesInvSboxMatrixMult:DWORD
        EXTRN   _SymCryptAesInvSbox:BYTE


BEFORE_PROC     MACRO
        ;
        ; Our current x86 compiler inserts 5 0xcc bytes before every function
        ; and starts every function with a 2-byte NOP.
        ; This supports hot-patching.
        ;
        DB      5 dup (0cch)
                ENDM
        

;=====================================================================
;       AesEncrypt & AesDecrypt Macros
;

; Shorthand for the 4 tables we will use
      
        
SMM0    EQU     _SymCryptAesSboxMatrixMult
SMM1    EQU     _SymCryptAesSboxMatrixMult + 0400h
SMM2    EQU     _SymCryptAesSboxMatrixMult + 0800h
SMM3    EQU     _SymCryptAesSboxMatrixMult + 0c00h

         
ISMM0    EQU     _SymCryptAesInvSboxMatrixMult
ISMM1    EQU     _SymCryptAesInvSboxMatrixMult + 0400h
ISMM2    EQU     _SymCryptAesInvSboxMatrixMult + 0800h
ISMM3    EQU     _SymCryptAesInvSboxMatrixMult + 0c00h

        
ENC_MIX MACRO   load_into_esi
        ;
        ; Perform the unkeyed mixing function for encryption
        ; load_into_esi is the value loaded into esi by the end
        ;
        ; input block is in      eax, ebx, edx, ebp
        ; New state ends up in   ecx, edi, eax, ebp

        push    ebp
        
        movzx   ecx,al                  
        mov     ecx,[SMM0 + 4 * ecx]
        movzx   esi,ah
        shr     eax,16
        mov     ebp,[SMM1 + 4 * esi]
        movzx   edi,ah
        mov     edi,[SMM3 + 4 * edi]
        movzx   eax,al
        mov     eax,[SMM2 + 4 * eax]

        movzx   esi,bl
        xor     edi,[SMM0 + 4 * esi]
        movzx   esi,bh
        shr     ebx,16
        xor     ecx,[SMM1 + 4 * esi]
        movzx   esi,bl
        xor     ebp,[SMM2 + 4 * esi]
        movzx   ebx,bh
        xor     eax,[SMM3 + 4 * ebx]

        pop     ebx
        
        movzx   esi,dl
        xor     eax,[SMM0 + 4 * esi]
        movzx   esi,dh
        xor     edi,[SMM1 + 4 * esi]
        shr     edx,16
        movzx   esi,dl
        xor     ecx,[SMM2 + 4 * esi]
        movzx   edx,dh
        xor     ebp,[SMM3 + 4 * edx]
        
        mov     esi,[load_into_esi]
        
        movzx   edx,bl
        xor     ebp,[SMM0 + 4 * edx]
        movzx   edx,bh
        xor     eax,[SMM1 + 4 * edx]
        shr     ebx,16
        movzx   edx,bl
        xor     edi,[SMM2 + 4 * edx]
        movzx   ebx,bh
        xor     ecx,[SMM3 + 4 * ebx]

        ENDM


DEC_MIX MACRO   load_into_esi
        ;
        ; Perform the unkeyed mixing function for decryption
        ; load_into_esi is the value loaded into esi by the end
        ;
        ; input block is in      eax, ebx, edx, ebp
        ; New state ends up in   ecx, edi, eax, ebp

        push    ebp
        
        movzx   ecx,al                  
        mov     ecx,[ISMM0 + 4 * ecx]
        movzx   esi,ah
        shr     eax,16
        mov     edi,[ISMM1 + 4 * esi]
        movzx   ebp,ah
        mov     ebp,[ISMM3 + 4 * ebp]
        movzx   eax,al
        mov     eax,[ISMM2 + 4 * eax]

        movzx   esi,bl
        xor     edi,[ISMM0 + 4 * esi]
        movzx   esi,bh
        shr     ebx,16
        xor     eax,[ISMM1 + 4 * esi]
        movzx   esi,bl
        xor     ebp,[ISMM2 + 4 * esi]
        movzx   ebx,bh
        xor     ecx,[ISMM3 + 4 * ebx]

        pop     ebx
        
        movzx   esi,dl
        xor     eax,[ISMM0 + 4 * esi]
        movzx   esi,dh
        xor     ebp,[ISMM1 + 4 * esi]
        shr     edx,16
        movzx   esi,dl
        xor     ecx,[ISMM2 + 4 * esi]
        movzx   edx,dh
        xor     edi,[ISMM3 + 4 * edx]
        
        mov     esi,[load_into_esi]
        
        movzx   edx,bl
        xor     ebp,[ISMM0 + 4 * edx]
        movzx   edx,bh
        xor     ecx,[ISMM1 + 4 * edx]
        shr     ebx,16
        movzx   edx,bl
        xor     edi,[ISMM2 + 4 * edx]
        movzx   ebx,bh
        xor     eax,[ISMM3 + 4 * ebx]

        ENDM


ADD_KEY MACRO   keyptr
        ;
        ; Input is block in     ecx, edi, eax, ebp
        ; keyptr points to the round key
        ; Output is in          eax, ebx, edx, ebp
        ;
        
        mov     edx, [keyptr+8]
        xor     edx, eax
        mov     eax, [keyptr]
        xor     eax, ecx
        xor     ebp, [keyptr+12]
        mov     ebx, [keyptr+4]
        xor     ebx, edi
        
        ENDM
        


AES_ENC MACRO   load_into_esi_offset
        ;
        ; Plaintext in eax,ebx,edx,ebp
        ; ecx points to first round key to use
        ; [key_limit] is last key to use
        ; [key_ptr] is temp storage area on stack
        ;
        ; Ciphertext ends up in ecx,edi,eax,ebp
        ;
        ; Loads [esp+load_into_esi_offset] into esi, except of offset = -1
        ;
       
        xor     eax,[ecx]
        xor     ebx,[ecx+4]
        xor     edx,[ecx+8]
        xor     ebp,[ecx+12]
        
        lea     ecx,[ecx+16]
        mov     [key_ptr],ecx                    
        
        align   16
@@:
        ; Block is in eax,ebx,edx,ebp
        ; ecx points to next round key

        ENC_MIX key_ptr
        ADD_KEY esi
        
        add     esi,16
        cmp     esi,[key_limit]
       
        mov     [key_ptr],esi                    
       
        jc      @B

        push    ebp
        
        movzx   ecx,al
        movzx   ecx,byte ptr SMM0[1 + 4 * ecx]
        movzx   esi,ah
        shr     eax,16
        movzx   ebp,byte ptr SMM0[1 + 4 * esi]
        movzx   edi,ah
        shl     ebp,8
        movzx   edi,byte ptr SMM0[1 + 4 * edi]
        movzx   eax,al
        shl     edi,24
        movzx   eax,byte ptr SMM0[1 + 4 * eax]
        shl     eax,16
        
        movzx   esi,bl
        movzx   esi,byte ptr SMM0[1 + 4 * esi]
        or      edi,esi
        movzx   esi,bh
        shr     ebx,16
        movzx   esi,byte ptr SMM0[1 + 4 * esi]
        shl     esi,8
        or      ecx,esi
        movzx   esi,bl
        movzx   esi,byte ptr SMM0[1 + 4 * esi]
        movzx   ebx,bh
        shl     esi,16
        movzx   ebx,byte ptr SMM0[1 + 4 * ebx]
        or      ebp,esi
        shl     ebx,24
        or      eax,ebx
        
        movzx   esi,dl
        movzx   esi,byte ptr SMM0[1 + 4 * esi]
        movzx   ebx,dh
        shr     edx,16
        movzx   ebx,byte ptr SMM0[1 + 4 * ebx]
        or      eax,esi
        shl     ebx,8
        movzx   esi,dl
        movzx   esi,byte ptr SMM0[1 + 4 * esi]
        or      edi,ebx
        pop     ebx
        movzx   edx,dh
        movzx   edx,byte ptr SMM0[1 + 4 * edx]
        shl     esi,16
        or      ecx,esi
        shl     edx,24
        or      ebp,edx
        
        movzx   esi,bl
        movzx   esi,byte ptr SMM0[1 + 4 * esi]
        movzx   edx,bh
        shr     ebx,16
        movzx   edx,byte ptr SMM0[1 + 4 * edx]
        or      ebp,esi
        shl     edx,8
        or      eax,edx
        mov     edx,[key_ptr]
        movzx   esi,bl
        movzx   esi,byte ptr SMM0[1 + 4 * esi]
        movzx   ebx,bh
        movzx   ebx,byte ptr SMM0[1 + 4 * ebx]
        shl     esi,16
        shl     ebx,24
        or      edi,esi

        IF      load_into_esi_offset NE -1
        mov     esi,[esp+load_into_esi_offset]
        ENDIF
        
        or      ecx,ebx

        
        xor     ecx,[edx]
        xor     edi,[edx+4]
        xor     eax,[edx+8]
        xor     ebp,[edx+12]

        ENDM

AES_DEC MACRO   load_into_esi_offset
        ;        
        ;
        ; Ciphertext in eax,ebx,edx,ebp
        ; ecx points to first round key to use
        ; [key_limit] is last key to use
        ; [key_ptr] is temp storage area on stack
        ;
        ; Plaintext ends up in eax,ebc,edx,ebp
        ;

        xor     eax,[ecx]
        xor     ebx,[ecx+4]
        xor     edx,[ecx+8]
        xor     ebp,[ecx+12]
        
        lea     ecx,[ecx+16]
        mov     [key_ptr],ecx

        align   16
@@:
        ; Block is in eax,ebx,edx,ebp
        ; ecx points to next round key

        DEC_MIX key_ptr
        ADD_KEY esi

        add     esi,16
        cmp     esi,[key_limit]
       
        mov     [key_ptr],esi                    
       
        jc      @B

        
        push    ebp
        
        movzx   ecx,al
        movzx   ecx,_SymCryptAesInvSbox[ecx]
        movzx   edi,ah
        shr     eax,16
        movzx   edi,_SymCryptAesInvSbox[edi]
        movzx   esi,ah
        shl     edi,8
        movzx   ebp,_SymCryptAesInvSbox[esi]
        movzx   eax,al
        shl     ebp,24
        movzx   eax,_SymCryptAesInvSbox[eax]
        shl     eax,16
        
        movzx   esi,bl
        movzx   esi,_SymCryptAesInvSbox[esi]
        or      edi,esi
        movzx   esi,bh
        shr     ebx,16
        movzx   esi,_SymCryptAesInvSbox[esi]
        shl     esi,8
        or      eax,esi
        movzx   esi,bl
        movzx   esi,_SymCryptAesInvSbox[esi]
        movzx   ebx,bh
        shl     esi,16
        movzx   ebx,_SymCryptAesInvSbox[ebx]
        or      ebp,esi
        shl     ebx,24
        or      ecx,ebx
        
        movzx   esi,dl
        movzx   esi,_SymCryptAesInvSbox[esi]
        movzx   ebx,dh
        shr     edx,16
        movzx   ebx,_SymCryptAesInvSbox[ebx]
        or      eax,esi
        shl     ebx,8
        movzx   esi,dl
        movzx   esi,_SymCryptAesInvSbox[esi]
        or      ebp,ebx
        pop     ebx
        movzx   edx,dh
        movzx   edx,_SymCryptAesInvSbox[edx]
        shl     esi,16
        or      ecx,esi
        shl     edx,24
        or      edi,edx
        
        movzx   esi,bl
        movzx   esi,_SymCryptAesInvSbox[esi]
        movzx   edx,bh
        shr     ebx,16
        movzx   edx,_SymCryptAesInvSbox[edx]
        or      ebp,esi
        shl     edx,8
        or      ecx,edx
        mov     edx,[key_ptr]
        movzx   esi,bl
        movzx   esi,_SymCryptAesInvSbox[esi]
        movzx   ebx,bh
        movzx   ebx,_SymCryptAesInvSbox[ebx]
        shl     esi,16
        shl     ebx,24
        or      edi,esi
        
        IF      load_into_esi_offset NE -1
        mov     esi,[esp+load_into_esi_offset]
        ENDIF
        
        or      eax,ebx
        
        xor     ecx,[edx]
        xor     edi,[edx+4]
        xor     eax,[edx+8]
        xor     ebp,[edx+12]

        ENDM


        if      0       ; We use the macro throughout, no need for the internal Enc/Dec routines

;=====================================================================
;       Internal AesEncrypt & AesDecrypt
;

;
; SymCryptAesEncryptAsmInternal
;
; Internal AES encryption routine with modified calling convention.
; This is a bare-bones AES encryption routine which can only be called from assembler code
; as the calling convention is modified.
;
; Input: plaintext in eax,ebx,edx,ebp
;        ecx points to first round key to use
;       [esp+8] points to last round key to use (key_limit)
;       [esp+4] is scratch area on stack
;
; Output: ciphertext in ecx,edi,eax,ebp
;         The stack is unchanged.
;
; To call this function you push two values on the stack: the key limit and a scratch space value.
; Note that key_limit remains the same for most applications that need multiple AES encryptions.
; For example, a CBC implementation can leave key_limit and the scratch space on the stack throughout the main loop.
;
; This function uses one stack variable for temporary storage. This is located just above the return address;
; callers should wipe this area before returning as it contains keying material.
;
        BEFORE_PROC
        
        align   16              ; We align this function for speed reasons
        
@SymCryptAesEncryptAsmInternal@16   PROC
        .FPO(0,2,0,0,0,0)

key_limit       equ     esp+8
key_ptr         equ     esp+4
        ;        
        ; Plaintext in eax,ebx,edx,ebp
        ; ecx points to first round key to use
        ; [key_limit] is last key to use
        ; [key_ptr] is temp storage area on stack
        ;
        ; Ciphertext ends up in ecx,edi,eax,ebp
        ;
        AES_ENC -1
       
        ret
        
@SymCryptAesEncryptAsmInternal@16   ENDP


;
; SymCryptAesDecryptAsmInternal
;
; Internal AES decryption routine with modified calling convention.
; This is a bare-bones AES decryption routine which can only be called from assembler code
; as the calling convention is modified.
;
; Input: ciphertext in eax,ebx,edx,ebp
;        ecx points to first round key to use
;       [esp+8] points to last round key to use (key_limit)
;       [esp+4] is scratch area on stack
;
; Output: plaintext in ecx,edi,eax,ebp
;         The stack is unchanged.
;
; To call this function you push two values on the stack: the key limit and a scratch space value.
; Note that key_limit remains the same for most applications that need multiple AES encryptions.
; For example, a CBC implementation can leave key_limit and the scratch space on the stack throughout the main loop.
;
; This function uses one stack variable for temporary storage. This is located just above the return address;
; callers should wipe this area before returning as it contains keying material.
;
        BEFORE_PROC
        
        align   16
        
@SymCryptAesDecryptAsmInternal@16   PROC
        .FPO(0,2,0,0,0,0)

key_limit       equ     esp+8
key_ptr         equ     esp+4
        ;
        ; Ciphertext in eax,ebx,edx,ebp
        ; ecx points to first round key to use
        ; [key_limit] is last key to use
        ; [key_ptr] is temp storage area on stack
        ; [tmp_buffer] is 16-byte temp buffer
        ;
        ; Plaintext ends up in eax,ebc,edx,ebp
        ;

        AES_DEC -1
        
        ret
@SymCryptAesDecryptAsmInternal@16   ENDP

        endif


        BEFORE_PROC

@SymCryptAesEncryptAsm@12 PROC
;VOID
;SYMCRYPT_CALL
;SymCryptAesEncrypt( _In_                                   PCSYMCRYPT_AES_EXPANDED_KEY pExpandedKey,
;                    _In_reads_bytes_( SYMCRYPT_AES_BLOCK_LEN )  PCBYTE                      pbPlaintext,
;                    _Out_writes_bytes_( SYMCRYPT_AES_BLOCK_LEN ) PBYTE                       pbCiphertext );
;
;
; The .FPO provides debugging information.
; This stuff not well documented, 
; but here is the information I've gathered about the arguments to .FPO
; 
; In order:
; cdwLocals: Size of local variables, in DWords
; cdwParams: Size of parameters, in DWords. Given that this is all about
;            stack stuff, I'm assuming this is only about parameters passed
;            on the stack.
; cbProlog : Number of bytes in the prolog code. We have interleaved the
;            prolog code with work for better performance. Most uses of
;            .FPO seem to set this value to 0 anyway, which is what we
;            will do.
; cbRegs   : # registers saved in the prolog. 4 in our case
; fUseBP   : 0 if EBP is not used as base pointer, 1 if EBP is used as base pointer
; cbFrame  : Type of frame.
;            0 = FPO frame (no frame pointer)
;            1 = Trap frame (result of a CPU trap event)
;            2 = TSS frame
;
; Having looked at various occurrences of .FPO in the Windows code it
; seems to be used fairly sloppy, with lots of arguments left 0 even when
; they probably shouldn't be according to the spec.
;
        .FPO(6,1,0,4,0,0)

AesEncryptFrame struct  4, NONUNIQUE

key_pointer     dd      ?
lastRoundKey    dd      ?
SaveEdi         dd      ?
SaveEsi         dd      ?
SaveEbp         dd      ?
SaveEbx         dd      ?
ReturnAddress   dd      ?
Ciphertext      dd      ?

AesEncryptFrame ends

        ; ecx = AesKey
        ; edx = Plaintext
        ; [esp+4] = Ciphertext

        ;
        ; 2-byte NOP for hot patching
        ; This is what our current compiler does for every function, so we will follow
        ; that.
        ;
        mov     edi,edi

        ;
        ; Set up our stack frame
        ;
        push    ebx
        push    ebp
        push    esi
        push    edi
        sub     esp, 8
        
        
        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        ; Load the plaintext block into eax,ebx,edx,ebp
        
        mov     eax,[edx]
        mov     ebx,[edx+4]
        mov     ebp,[edx+12]
        mov     edx,[edx+8]     ; Plaintext ptr no longer needed

        ; Get the address of the last round key
        mov     esi,[ecx+SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]
        mov     [esp+AesEncryptFrame.lastRoundKey],esi

key_limit       equ     esp + AesEncryptFrame.lastRoundKey
key_ptr         equ     esp + AesEncryptFrame.key_pointer
        AES_ENC AesEncryptFrame.Ciphertext
;       call    @SymCryptAesEncryptAsmInternal@16

        ;mov     esi,[esp+AesEncryptFrame.Ciphertext]
        mov     [esi],ecx
        mov     [esi+4],edi
        mov     [esi+8],eax
        mov     [esi+12],ebp
        
        ; wipe the stack location we used for temporary pushes

        mov     [esp-8],esp

        add     esp,8
        pop     edi
        pop     esi
        pop     ebp
        pop     ebx
        ret     4
                
        
@SymCryptAesEncryptAsm@12 ENDP



        BEFORE_PROC
        
@SymCryptAesDecryptAsm@12 PROC
;VOID
;AesDecrypt( _In_                            PCADD_KEY   AesKey,
;            _In_reads_bytes_(AES_BLOCK_SIZE)     PCBYTE      Ciphertext,
;            _Out_writes_bytes_(AES_BLOCK_SIZE)    PBYTE       Plaintext
;            )

        .FPO(6,1,0,4,0,0)
        
AesDecryptFrame struct  4, NONUNIQUE

key_pointer     dd      ?
lastRoundKey    dd      ?
SaveEdi         dd      ?
SaveEsi         dd      ?
SaveEbp         dd      ?
SaveEbx         dd      ?
ReturnAddress   dd      ?
Plaintext       dd      ?

AesDecryptFrame ends

        ; ecx = AesKey
        ; edx = Ciphertext
        ; [esp+4] = Plaintext

        ;
        ; 2-byte NOP for hot patching
        ; This is what our current compiler does for every function, so we will follow
        ; that.
        ;
        mov     edi,edi

        ;
        ; Set up our stack frame
        ;
        push    ebx
        push    ebp
        push    esi
        push    edi
        sub     esp, 8


        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        ; Load the ciphertext block into eax,ebx,edx,ebp
        
        mov     eax,[edx]
        mov     ebx,[edx+4]
        mov     ebp,[edx+12]
        mov     edx,[edx+8]     ; Ciphertext ptr no longer needed


        ; Get the address of the last round key
        mov     esi,[ecx+SYMCRYPT_AES_EXPANDED_KEY.lastDecRoundKey]       ; esi = lastDecRoundKey
        mov     ecx,[ecx+SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]       ; ecx = lastEncRoundKey = first Dec round key
        mov     [esp+AesDecryptFrame.lastRoundKey],esi

key_limit       equ     esp + AesDecryptFrame.lastRoundKey
key_ptr         equ     esp + AesDecryptFrame.key_pointer
        AES_DEC AesDecryptFrame.Plaintext

        
        mov     [esi],ecx
        mov     [esi+4],edi
        mov     [esi+8],eax
        mov     [esi+12],ebp
        
        mov     [esp-8],esp
        
        add     esp,8
        pop     edi
        pop     esi
        pop     ebp
        pop     ebx
        ret     4

        
@SymCryptAesDecryptAsm@12 ENDP




        BEFORE_PROC

@SymCryptAesCbcEncryptAsm@20 PROC
;VOID
;SYMCRYPT_CALL
;SymCryptAesCbcEncrypt( 
;    _In_                                    PCSYMCRYPT_AES_EXPANDED_KEY pExpandedKey,
;    _In_reads_bytes_( SYMCRYPT_AES_BLOCK_SIZE )  PBYTE                       pbChainingValue,
;    _In_reads_bytes_( cbData )                   PCBYTE                      pbSrc,
;    _Out_writes_bytes_( cbData )                  PBYTE                       pbDst,
;                                            SIZE_T                      cbData );
;
        .FPO(9,3,0,4,0,0)

AesCbcEncryptFrame struct  4, NONUNIQUE

key_pointer     dd      ?
lastRoundKey    dd      ?
pbEndDst        dd      ?
firstRoundKey   dd      ?
pbChainingValue dd      ?
SaveEdi         dd      ?
SaveEsi         dd      ?
SaveEbp         dd      ?
SaveEbx         dd      ?
ReturnAddress   dd      ?
pbSrc           dd      ?
pbDst           dd      ?
cbData          dd      ?

AesCbcEncryptFrame ends

        ; ecx = pExpandedKey
        ; edx = pbChainingValue
        ; [esp+4...] = pbSrc, pbDst, cbData

        ;
        ; 2-byte NOP for hot patching
        ; This is what our current compiler does for every function, so we will follow
        ; that.
        ;
        mov     edi,edi

        ;
        ; Set up our stack frame
        ;
        push    ebx
        push    ebp
        push    esi
        push    edi
        
        push    edx             ; pbChainingValue
        push    ecx             ; pbExpandedKey points to the first round key
        sub     esp, 12

        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        mov     eax,[esp + AesCbcEncryptFrame.cbData]
        and     eax, NOT 15
        jz      AesCbcEncryptDoNothing

        ; Get & store the address of the last round key
        mov     ebx,[ecx+SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]
        mov     [esp+AesCbcEncryptFrame.lastRoundKey],ebx

        
        mov     esi,[esp + AesCbcEncryptFrame.pbDst]
        add     eax,esi
        mov     [esp + AesCbcEncryptFrame.pbEndDst], eax

        ;
        ; Convert pbSrc to an offset from pbDst to reduce the # updates
        ; in a loop
        ;
        ;mov    ecx,[esp + AesCbcEncryptFrame.pbSrc]
        ;sub    ecx, esi
        ;mov    [esp + AesCbcEncryptFrame.pbSrc], ecx   

        ; esi = pbDst
        
        ; Load state from chaining value
        ; State is in ecx,edi,eax,ebp
        mov     ecx,[edx]
        mov     edi,[edx + 4]
        mov     eax,[edx + 8]
        mov     ebp,[edx + 12]

        
AesCbcEncryptLoop:
        ; Invariant:
        ;  State in (ecx, edi, eax, ebp)
        ;  esi = pbDst for next block

        ;
        ; Change esi to point to current pbSrc pointer. pbSrc is here an offset from pbDst.
        ;
        mov     esi,[esp + AesCbcEncryptFrame.pbSrc]

        ;
        ; Xor next plaintext block & move state to (eax, ebx, edx, ebp)
        ; We keep the reads sequentially to help the HW prefetch logic in the CPU
        ;
        xor     ecx, [esi]
        
        mov     ebx, [esi + 4]
        xor     ebx, edi
        
        mov     edx, [esi + 8]
        xor     edx, eax
        
        mov     eax, ecx
        
        xor     ebp, [esi + 12]

        add     esi, 16
        mov     [esp + AesCbcEncryptFrame.pbSrc], esi
        
        mov     ecx,[esp + AesCbcEncryptFrame.firstRoundKey]


key_limit       equ     esp + AesCbcEncryptFrame.lastRoundKey
key_ptr         equ     esp + AesCbcEncryptFrame.key_pointer
        AES_ENC AesCbcEncryptFrame.pbDst        ; argument is address that is loaded into esi

        ;call   @SymCryptAesEncryptAsmInternal@16
        ;mov    esi,[esp + AesCbcEncryptFrame.pbDst]
        
        mov     [esi], ecx
        mov     [esi + 4], edi
        mov     [esi + 8], eax
        mov     [esi + 12], ebp

        add     esi,16
        cmp     esi,[esp + AesCbcEncryptFrame.pbEndDst]
        mov     [esp + AesCbcEncryptFrame.pbDst], esi
        jb      AesCbcEncryptLoop

        mov     edx,[esp + AesCbcEncryptFrame.pbChainingValue]
        mov     [edx], ecx
        mov     [edx + 4], edi
        mov     [edx + 8], eax
        mov     [edx + 12], ebp

        ;
        ; Wipe the one stack location that the internal encrypt routine uses
        ; for temporary data storage
        ;
        mov     [esp - 8], esp

AesCbcEncryptDoNothing:

        add     esp, 20
        pop     edi
        pop     esi
        pop     ebp
        pop     ebx
        ret     12
        
        
@SymCryptAesCbcEncryptAsm@20 ENDP




        BEFORE_PROC

@SymCryptAesCbcDecryptAsm@20 PROC
;VOID
;SYMCRYPT_CALL
;SymCryptAesCbcDecrypt( 
;    _In_                                    PCSYMCRYPT_AES_EXPANDED_KEY pExpandedKey,
;    _In_reads_bytes_( SYMCRYPT_AES_BLOCK_SIZE )  PBYTE                       pbChainingValue,
;    _In_reads_bytes_( cbData )                   PCBYTE                      pbSrc,
;    _Out_writes_bytes_( cbData )                  PBYTE                       pbDst,
;                                            SIZE_T                      cbData );
;
        .FPO(13,3,0,4,0,0)

AesCbcDecryptFrame struct  4, NONUNIQUE

key_pointer     dd      ?
lastRoundKey    dd      ?
newChainValue   dd      4 dup (?)       ; New chaining value after the call
pbCurrentDst    dd      ?
firstRoundKey   dd      ?
pbChainingValue dd      ?
SaveEdi         dd      ?
SaveEsi         dd      ?
SaveEbp         dd      ?
SaveEbx         dd      ?
ReturnAddress   dd      ?
pbSrc           dd      ?
pbDst           dd      ?
cbData          dd      ?

AesCbcDecryptFrame ends

        ; ecx = pExpandedKey
        ; edx = pbChainingValue
        ; [esp+4...] = pbSrc, pbDst, cbData

        ;
        ; 2-byte NOP for hot patching
        ; This is what our current compiler does for every function, so we will follow
        ; that.
        ;
        mov     edi,edi

        ;
        ; Set up our stack frame
        ;
        push    ebx
        push    ebp
        push    esi
        push    edi
        
        push    edx             ; pbChainingValue
        sub     esp, 32

        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        mov     eax,[esp + AesCbcDecryptFrame.cbData]
        and     eax, NOT 15
        jz      AesCbcDecryptDoNothing

        ; Get & store the address of the first & last round key
        mov     ebx,[ecx+SYMCRYPT_AES_EXPANDED_KEY.lastDecRoundKey]
        mov     [esp+AesCbcDecryptFrame.lastRoundKey],ebx
        
        sub     eax, 16

        mov     ecx,[ecx + SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]           ; = first dec round key
        mov     [esp + AesCbcDecryptFrame.firstRoundKey], ecx

        mov     edi,[esp + AesCbcDecryptFrame.pbDst]
        add     edi, eax
        mov     [esp + AesCbcDecryptFrame.pbCurrentDst], edi    ; points to last block in buffer

        mov     esi,[esp + AesCbcDecryptFrame.pbSrc]
        add     esi, eax
        mov     [esp + AesCbcDecryptFrame.pbSrc], esi

        ;
        ; Load last block & store it for the chaining output
        ;
        mov     eax,[esi]
        mov     [esp + AesCbcDecryptFrame.newChainValue], eax
        mov     ebx,[esi + 4]
        mov     [esp + AesCbcDecryptFrame.newChainValue + 4], ebx
        mov     edx,[esi + 8]
        mov     [esp + AesCbcDecryptFrame.newChainValue + 8], edx
        mov     ebp,[esi + 12]
        mov     [esp + AesCbcDecryptFrame.newChainValue + 12], ebp

        jmp     AesCbcDecryptLoopEnter
        
AesCbcDecryptLoop:
        ; Invariant:
        ;  State in (ecx, edi, eax, ebp)
        ;  State is just after decrypt, but before feed-forward xor
        ;  esi = pbCurrentDst for just decrypted state
        ;  pbSrc = corresponding position in Src buffer

        mov     ebx,[esp + AesCbcDecryptFrame.pbSrc]
        
        mov     edx,[ebx - 16 + 8]
        xor     eax, edx
        mov     [esi + 16 + 8], eax

        mov     eax,[ebx - 16 + 0]
        xor     ecx, eax
        mov     [esi + 16 + 0], ecx
        
        lea     ecx, [ebx - 16]         ; decrement + move ptr to allow register shuffle

        mov     ebx,[ebx - 16 + 4]
        xor     edi, ebx
        mov     [esi + 16 + 4], edi

        mov     edi,[ecx + 12]
        xor     ebp, edi
        mov     [esi + 16 + 12], ebp
        mov     ebp, edi

        mov     [esp + AesCbcDecryptFrame.pbSrc], ecx

        mov     ecx,[esp + AesCbcDecryptFrame.firstRoundKey]
        
AesCbcDecryptLoopEnter:

key_limit       equ     esp + AesCbcDecryptFrame.lastRoundKey
key_ptr         equ     esp + AesCbcDecryptFrame.key_pointer

        AES_DEC AesCbcDecryptFrame.pbCurrentDst
        ;call   @SymCryptAesDecryptAsmInternal@16
        ;mov    esi,[esp + AesCbcDecryptFrame.pbCurrentDst]
        
        cmp     esi,[esp + AesCbcDecryptFrame.pbDst]
        lea     esi,[esi-16]
        mov     [esp + AesCbcDecryptFrame.pbCurrentDst], esi
        
        ja      AesCbcDecryptLoop

        ;
        ; Xor with chaining value and store last block (first in output buffer)
        ;
        
        mov     ebx,[esp + AesCbcDecryptFrame.pbChainingValue]
        xor     ecx,[ebx]
        mov     [esi + 16], ecx
        xor     edi,[ebx + 4]
        mov     [esi + 16 + 4], edi
        xor     eax,[ebx + 8]
        mov     [esi + 16 + 8], eax
        xor     ebp,[ebx + 12]
        mov     [esi + 16+12], ebp

        ;
        ; Set the new chaining value
        ;
        
        mov     eax,[esp + AesCbcDecryptFrame.newChainValue + 0]
        mov     [ebx + 0], eax
        mov     ecx,[esp + AesCbcDecryptFrame.newChainValue + 4]
        mov     [ebx + 4], ecx
        mov     eax,[esp + AesCbcDecryptFrame.newChainValue + 8]
        mov     [ebx + 8], eax
        mov     ecx,[esp + AesCbcDecryptFrame.newChainValue + 12]
        mov     [ebx + 12], ecx


        ; Wipe the one stack location that the internal encrypt routine uses
        ; for temporary data storage
        ;
        mov     [esp - 8], esp

AesCbcDecryptDoNothing:

        add     esp, 36
        pop     edi
        pop     esi
        pop     ebp
        pop     ebx
        ret     12
        
        
@SymCryptAesCbcDecryptAsm@20 ENDP


        BEFORE_PROC

@SymCryptAesCtrMsb64Asm@20 PROC
;VOID
;SYMCRYPT_CALL
;SymCryptAesCtrMsb64( 
;        _In_                                        PCSYMCRYPT_AES_EXPANDED_KEY pExpandedKey,
;        _Inout_updates_bytes_( SYMCRYPT_AES_BLOCK_SIZE )   PBYTE                       pbChainingValue,
;        _In_reads_bytes_( cbData )                       PCBYTE                      pbSrc,
;        _Out_writes_bytes_( cbData )                      PBYTE                       pbDst,
;                                                    SIZE_T                      cbData )

        .FPO(13,3,0,4,0,0)

AesCtrMsb64Frame struct  4, NONUNIQUE

key_pointer     dd      ?
lastRoundKey    dd      ?
chainValue      dd      4 dup (?)
pbEndDst        dd      ?
firstRoundKey   dd      ?
pbChainingValue dd      ?
SaveEdi         dd      ?
SaveEsi         dd      ?
SaveEbp         dd      ?
SaveEbx         dd      ?
ReturnAddress   dd      ?
pbSrc           dd      ?
pbDst           dd      ?
cbData          dd      ?

AesCtrMsb64Frame ends

        ; ecx = pExpandedKey
        ; edx = pbChainingValue
        ; [esp+4...] = pbSrc, pbDst, cbData

        ;
        ; 2-byte NOP for hot patching
        ; This is what our current compiler does for every function, so we will follow
        ; that.
        ;
        mov     edi,edi

        ;
        ; Set up our stack frame
        ;
        push    ebx
        push    ebp
        push    esi
        push    edi
        
        push    edx             ; pbChainingValue
        push    ecx             ; pbExpandedKey points to the first round key
        sub     esp, 28

        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        mov     eax,[esp + AesCtrMsb64Frame.cbData]
        and     eax, NOT 15
        jz      AesCtrMsb64DoNothing

        ; Get & store the address of the last round key
        mov     ebx,[ecx+SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]
        mov     [esp+AesCtrMsb64Frame.lastRoundKey],ebx

        
        mov     esi,[esp + AesCtrMsb64Frame.pbDst]
        add     eax,esi
        mov     [esp + AesCtrMsb64Frame.pbEndDst], eax

        ; esi = pbDst
        
        ; Load state from chaining value & copy into local stack
        ; State is in ecx,edi,eax,ebp
        mov     eax,[edx]
        mov     [esp + AesCtrMsb64Frame.chainValue], eax
        mov     ebx,[edx + 4]
        mov     [esp + AesCtrMsb64Frame.chainValue + 4], ebx
        mov     ebp,[edx + 12]
        mov     edx,[edx + 8]

                
AesCtrMsb64Loop:
        ; Invariant:
        ;  counter State in (eax, ebx, edx, ebp)
        ;  first 8 bytes of counter state in [esp+chainValue]

        ;
        ; Write the updated counter value to the local copy
        ;
        mov     [esp + AesCtrMsb64Frame.chainValue + 8], edx
        mov     ecx,[esp + AesCtrMsb64Frame.firstRoundKey]
        mov     [esp + AesCtrMsb64Frame.chainValue + 12], ebp

key_limit       equ     esp + AesCtrMsb64Frame.lastRoundKey
key_ptr         equ     esp + AesCtrMsb64Frame.key_pointer
        
        AES_ENC AesCtrMsb64Frame.pbSrc
        ;       result is in (ecx, edi, eax, ebp)
        ;       esi = pbSrc

        mov     ebx,[esp + AesCtrMsb64Frame.pbDst]

        ;
        ; Read the Src block, xor it with the state, and write it to Dst
        ;
        xor     ecx,[esi]
        mov     [ebx],ecx
        xor     edi,[esi+4]
        mov     [ebx+4],edi
        xor     eax,[esi+8]
        mov     [ebx+8],eax
        xor     ebp,[esi+12]
        mov     [ebx+12],ebp
        
        add     esi, 16
        mov     [esp + AesCtrMsb64Frame.pbSrc], esi
        
        lea     ecx,[ebx + 16]                  ; increment and move pointer to allow reg shuffle

        ;
        ; Load the current chain value, and do the increment 
        ;
        mov     ebp,[esp + AesCtrMsb64Frame.chainValue+12]
        bswap   ebp
        mov     edx,[esp + AesCtrMsb64Frame.chainValue+8]
        bswap   edx
        add     ebp,1
        mov     eax,[esp + AesCtrMsb64Frame.chainValue]
        adc     edx, 0
        mov     ebx,[esp + AesCtrMsb64Frame.chainValue+4]
        bswap   ebp
        bswap   edx


        cmp     ecx,[esp + AesCtrMsb64Frame.pbEndDst]   
        mov     [esp + AesCtrMsb64Frame.pbDst], ecx

        jb      AesCtrMsb64Loop

        ;
        ; Write the updated chaining value; we only need to update 8 bytes
        ;
        mov     ebx,[esp + AesCtrMsb64Frame.pbChainingValue]
        mov     [ebx + 8], edx
        mov     [ebx + 12], ebp

        ;
        ; Wipe our local copy of the chaining value
        ;
        xor     eax,eax
        mov     [esp + AesCtrMsb64Frame.chainValue], eax
        mov     [esp + AesCtrMsb64Frame.chainValue + 4], eax
        mov     [esp + AesCtrMsb64Frame.chainValue + 8], eax
        mov     [esp + AesCtrMsb64Frame.chainValue + 12], eax
        
        ;
        ; Wipe the one stack location that the internal encrypt routine uses
        ; for temporary data storage
        ;
        mov     [esp - 8], esp

AesCtrMsb64DoNothing:

        add     esp, 36
        pop     edi
        pop     esi
        pop     ebp
        pop     ebx
        ret     12
        
        
@SymCryptAesCtrMsb64Asm@20 ENDP


        if 0    ; disabled while we concentrate on reaching RSA32 parity. The code below works though.


        BEFORE_PROC

@SymCryptAesCbcMacAsm@16 PROC
;VOID
;SYMCRYPT_CALL
;SymCryptAesCbcMac( 
;        _In_                                        PCSYMCRYPT_AES_EXPANDED_KEY pExpandedKey,
;        _Inout_updates_bytes_( SYMCRYPT_AES_BLOCK_SIZE )   PBYTE                       pbChainingValue,
;        _In_reads_bytes_( cbData )                       PCBYTE                      pbData,
;                                                    SIZE_T                      cbData )
;
        .FPO(9,2,0,4,0,0)

AesCbcMacFrame struct  4, NONUNIQUE

key_pointer     dd      ?
lastRoundKey    dd      ?
pbEnd           dd      ?
firstRoundKey   dd      ?
pbChainingValue dd      ?
SaveEdi         dd      ?
SaveEsi         dd      ?
SaveEbp         dd      ?
SaveEbx         dd      ?
ReturnAddress   dd      ?
pbData          dd      ?
cbData          dd      ?

AesCbcMacFrame ends

        ; ecx = pExpandedKey
        ; edx = pbChainingValue
        ; [esp+4...] = pbSrc, pbDst, cbData

        ;
        ; 2-byte NOP for hot patching
        ; This is what our current compiler does for every function, so we will follow
        ; that.
        ;
        mov     edi,edi

        ;
        ; Set up our stack frame
        ;
        push    ebx
        push    ebp
        push    esi
        push    edi
        
        push    edx             ; pbChainingValue
        push    ecx             ; pbExpandedKey points to the first round key
        sub     esp, 12

        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        mov     eax,[esp + AesCbcMacFrame.cbData]
        and     eax, NOT 15
        jz      AesCbcMacDoNothing

        ; Get & store the address of the last round key
        mov     ebx,[ecx+SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]
        mov     [esp+AesCbcMacFrame.lastRoundKey],ebx

        
        mov     esi,[esp + AesCbcMacFrame.pbData]
        add     eax,esi
        mov     [esp + AesCbcMacFrame.pbEnd], eax

        ; esi = pbData
        
        ; Load state from chaining value
        ; State is in ecx,edi,eax,ebp
        mov     ecx,[edx]
        mov     edi,[edx + 4]
        mov     eax,[edx + 8]
        mov     ebp,[edx + 12]

        
AesCbcMacLoop:
        ; Invariant:
        ;  State in (ecx, edi, eax, ebp)
        ;  esi = pbData

        ;
        ; Xor next plaintext block & move state to (eax, ebx, edx, ebp)
        ; We keep the reads sequentially to help the HW prefetch logic in the CPU
        ;
        xor     ecx, [esi]
        
        mov     ebx, [esi + 4]
        xor     ebx, edi
        
        mov     edx, [esi + 8]
        xor     edx, eax
        
        mov     eax, ecx
        
        xor     ebp, [esi + 12]

        mov     ecx,[esp + AesCbcMacFrame.firstRoundKey]


key_limit       equ     esp + AesCbcMacFrame.lastRoundKey
key_ptr         equ     esp + AesCbcMacFrame.key_pointer
        AES_ENC AesCbcMacFrame.pbData           ; argument is address that is loaded into esi

        ;call   @SymCryptAesEncryptAsmInternal@16
        ;mov    esi,[esp + AesCbcMacFrame.pbData]

        add     esi, 16
        cmp     esi,[esp + AesCbcMacFrame.pbEnd]
        mov     [esp + AesCbcMacFrame.pbData], esi
        jb      AesCbcMacLoop

        mov     edx,[esp + AesCbcMacFrame.pbChainingValue]
        mov     [edx], ecx
        mov     [edx + 4], edi
        mov     [edx + 8], eax
        mov     [edx + 12], ebp

        ;
        ; Wipe the one stack location that the internal encrypt routine uses
        ; for temporary data storage
        ;
        mov     [esp - 8], esp

AesCbcMacDoNothing:

        add     esp, 20
        pop     edi
        pop     esi
        pop     ebp
        pop     ebx
        ret     8
        
        
@SymCryptAesCbcMacAsm@16 ENDP

        endif



;===========================================================================
;       AES-NI code


if 0    ; No longer used; replaced with intrinsic C code that can be inlined.

        BEFORE_PROC

@SymCryptAes4SboxXmm@8       PROC
;
;VOID
;Aes4SboxAsm( _In_reads_bytes_(4) PCBYTE pIn, _Out_writes_bytes_(4) PBYTE pOut );
;
        .FPO(0,0,0,0,0,0)
        ;
        ;ecx points to source 
        ;edx points to destination
        ;
        ;We only use volatile registers so we do not have to save any registers.
        ;

        mov     eax,[ecx]       ; Use a register to avoid alignment issues
        movd    xmm0, eax

        movsldup        xmm0, xmm0      ; copy [31:0] to [63:32]
        aeskeygenassist xmm0, xmm0, 0

        movd    eax, xmm0
        mov     [edx], eax

        ret

@SymCryptAes4SboxXmm@8       ENDP


        BEFORE_PROC
        
@SymCryptAesCreateDecryptionRoundKeyXmm@8       PROC
;
;VOID
;AesCreateDecryptionRoundKeyAsm( _In_reads_bytes_(16) PCBYTE pEncryptionRoundKey, 
;                                _Out_writes_bytes_(16) PBYTE pDecryptionRoundKey );
;
        .FPO(0,0,0,0,0,0)
        ;ecx points to source
        ;edx points to destination

        movups  xmm0,[ecx]
        aesimc  xmm0, xmm0
        movups  [edx], xmm0
        ret

@SymCryptAesCreateDecryptionRoundKeyXmm@8       ENDP

endif



AES_ENCRYPT_XMM MACRO
        ; xmm0 contains the plaintext
        ; ecx points to first round key to use
        ; eax is last key to use (unchanged)
        ; Ciphertext ends up in xmm0, xmm1 used
        ;

        ;
        ; xor in first round key; round keys are 16-aligned on amd64
        ;
        movups  xmm1, [ecx]
        pxor    xmm0, xmm1
        movups  xmm1, [ecx+16]
        aesenc  xmm0, xmm1
        
        add     ecx, 32

@@:
        ; r9 points to next round key
        movups  xmm1, [ecx]
        aesenc  xmm0, xmm1

        movups  xmm1, [ecx + 16]
        aesenc  xmm0, xmm1
        
        add     ecx, 32
        cmp     ecx, eax
        jc      @B

        ;
        ; Now for the final round
        ;
        movups          xmm1, [eax]
        aesenclast      xmm0, xmm1
       
        ENDM


AES_DECRYPT_XMM MACRO
        ; xmm0 contains the plaintext
        ; ecx points to first round key to use
        ; eax is last key to use (unchanged)
        ; Ciphertext ends up in xmm0, xmm1 used
        ;

        ;
        ; xor in first round key; round keys are 16-aligned on amd64
        ;
        movups  xmm1, [ecx]
        pxor    xmm0, xmm1
        movups  xmm1, [ecx+16]
        aesdec  xmm0, xmm1
        
        add     ecx, 32

@@:
        ; r9 points to next round key
        movups  xmm1, [ecx]
        aesdec  xmm0, xmm1

        movups  xmm1, [ecx + 16]
        aesdec  xmm0, xmm1
        
        add     ecx, 32
        cmp     ecx, eax
        jc      @B

        ;
        ; Now for the final round
        ;
        movups          xmm1, [eax]
        aesdeclast      xmm0, xmm1
       
        ENDM



        BEFORE_PROC
        
if 0
@SymCryptAesEncryptXmm@12       PROC
        ;
        ; rcx = expanded key
        ; rdx = pbSrc
        ; [esp+4] = pbDst

        .FPO( 0, 1, 0, 0, 0, 0)

        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        movups  xmm0,[edx]
        mov     eax, [ecx + SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]
        
        
        AES_ENCRYPT_XMM
        ; xmm0 contains the plaintext
        ; ecx points to first round key to use
        ; eax is last key to use (unchanged)
        ; Ciphertext ends up in xmm0

        mov     ecx,[esp + 4]
        
        movups  [ecx],xmm0

        ret     4
        
@SymCryptAesEncryptXmm@12       ENDP

endif        
if 0
        BEFORE_PROC
        
@SymCryptAesDecryptXmm@12       PROC
        ;
        ; rcx = expanded key
        ; rdx = pbSrc
        ; [esp+4] = pbDst

        .FPO( 0, 1, 0, 0, 0, 0)
        
        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        movups  xmm0,[edx]
        mov     eax, [ecx + SYMCRYPT_AES_EXPANDED_KEY.lastDecRoundKey]
        mov     ecx, [ecx + SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]
        
        
        AES_DECRYPT_XMM
        ; xmm0 contains the plaintext
        ; ecx points to first round key to use
        ; eax is last key to use (unchanged)
        ; Ciphertext ends up in xmm0

        mov     ecx,[esp + 4]
        
        movups  [ecx],xmm0

        ret     4
        
@SymCryptAesDecryptXmm@12       ENDP
        
endif


if 0
        BEFORE_PROC

@SymCryptAesCbcEncryptXmm@20 PROC
        ; ecx = pExpandedKey
        ; edx = pbChainingValue
        ; [esp+4...] = pbSrc, pbDst, cbData

        .FPO    (4, 3, 0, 4, 0, 0 )     ; locals, params, 0, regs saved, 0, 0

SymCryptAesCbcEncryptXmmFrame struct  4, NONUNIQUE

SaveEdi         dd      ?
SaveEsi         dd      ?
SaveEbp         dd      ?
SaveEbx         dd      ?
ReturnAddress   dd      ?
pbSrc           dd      ?
pbDst           dd      ?
cbData          dd      ?

SymCryptAesCbcEncryptXmmFrame ends

        ;
        ; 2-byte NOP for hot patching
        ; This is what our current compiler does for every function, so we will follow
        ; that.
        ;
        mov     edi,edi
        push    ebx
        push    ebp
        push    esi
        push    edi

        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        mov     ebp,[esp + SymCryptAesCbcEncryptXmmFrame.cbData]

        and     ebp, NOT 15
        jz      SymCryptAesCbcEncryptXmmNoData

        mov     esi,[esp +  SymCryptAesCbcEncryptXmmFrame.pbSrc]
        mov     edi,[esp +  SymCryptAesCbcEncryptXmmFrame.pbDst]
        
        add     ebp, esi                        ; ebp = pbSrcEnd

        movups  xmm0,[edx]
        mov     eax, [ecx + SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]
        mov     ebx, ecx
        

SymCryptAesCbcEncryptXmmLoop:
        movups  xmm1, [esi]
        pxor    xmm0, xmm1
        add     esi, 16
        
        mov     ecx, ebx

        AES_ENCRYPT_XMM

        movups  [edi], xmm0
        add     edi, 16
        cmp     esi, ebp
        jc      SymCryptAesCbcEncryptXmmLoop

        movups  [edx], xmm0

SymCryptAesCbcEncryptXmmNoData:

        pop     edi
        pop     esi
        pop     ebp
        pop     ebx

        ret     12

        
@SymCryptAesCbcEncryptXmm@20 ENDP

endif


if 0    ; replaced with C/intrinsic code

        BEFORE_PROC

@SymCryptAesCbcDecryptXmm@20 PROC
        ; ecx = pExpandedKey
        ; edx = pbChainingValue
        ; [esp+4...] = pbSrc, pbDst, cbData

        .FPO    (4, 3, 0, 4, 0, 0 )     ; locals, params, 0, regs saved, 0, 0

SymCryptAesCbcDecryptXmmFrame struct  4, NONUNIQUE

SaveEdi         dd      ?
SaveEsi         dd      ?
SaveEbp         dd      ?
SaveEbx         dd      ?
ReturnAddress   dd      ?
pbSrc           dd      ?
pbDst           dd      ?
cbData          dd      ?

SymCryptAesCbcDecryptXmmFrame ends

        ;
        ; 2-byte NOP for hot patching
        ; This is what our current compiler does for every function, so we will follow
        ; that.
        ;
        mov     edi,edi
        push    ebx
        push    ebp
        push    esi
        push    edi

        SYMCRYPT_CHECK_MAGIC    ecx, SYMCRYPT_AES_EXPANDED_KEY
        
        mov     ebp,[esp + SymCryptAesCbcDecryptXmmFrame.cbData]

        and     ebp, NOT 15
        jz      SymCryptAesCbcDecryptXmmNoData

        mov     esi,[esp + SymCryptAesCbcDecryptXmmFrame.pbSrc]
        mov     edi,[esp + SymCryptAesCbcDecryptXmmFrame.pbDst]
        
        add     ebp, esi                        ; ebp = pbSrcEnd

        movups  xmm3,[edx]
        mov     eax, [ecx + SYMCRYPT_AES_EXPANDED_KEY.lastDecRoundKey]
        mov     ebx, [ecx + SYMCRYPT_AES_EXPANDED_KEY.lastEncRoundKey]
        

SymCryptAesCbcDecryptXmmLoop:
        movups  xmm0, [esi]
        add     esi, 16
        
        movaps  xmm2, xmm0
        
        mov     ecx, ebx

        AES_DECRYPT_XMM

        pxor    xmm0, xmm3
        
        movaps  xmm3, xmm2
        
        movups  [edi], xmm0
        add     edi, 16
        cmp     esi, ebp
        jc      SymCryptAesCbcDecryptXmmLoop

        movups  [edx], xmm2

SymCryptAesCbcDecryptXmmNoData:

        pop     edi
        pop     esi
        pop     ebp
        pop     ebx

        ret     12

        
@SymCryptAesCbcDecryptXmm@20 ENDP

endif;

_TEXT   ENDS

END


