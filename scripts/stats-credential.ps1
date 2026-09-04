Set-StrictMode -Version Latest

$script:StatsCredentialTarget = 'QuickkNastyy/ProfileStats/STATS_TOKEN'
$script:StatsCredentialUser = 'QuickkNastyy'

if (-not ('QuickkNastyyProfileStats.CredentialManager' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace QuickkNastyyProfileStats
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct CREDENTIAL
    {
        public UInt32 Flags;
        public UInt32 Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    public static class CredentialManager
    {
        private const UInt32 CRED_TYPE_GENERIC = 1;
        private const UInt32 CRED_PERSIST_LOCAL_MACHINE = 2;
        private const Int32 ERROR_NOT_FOUND = 1168;

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, UInt32 flags);

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, UInt32 type, UInt32 flags, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, UInt32 type, UInt32 flags);

        [DllImport("advapi32.dll", SetLastError = false)]
        private static extern void CredFree(IntPtr credentialPtr);

        public static void Write(string target, string userName, string secret)
        {
            if (String.IsNullOrWhiteSpace(target)) throw new ArgumentException("target is required", "target");
            if (String.IsNullOrEmpty(secret)) throw new ArgumentException("secret is required", "secret");

            byte[] secretBytes = Encoding.UTF8.GetBytes(secret);
            IntPtr targetPtr = IntPtr.Zero;
            IntPtr userPtr = IntPtr.Zero;
            IntPtr blobPtr = IntPtr.Zero;

            try
            {
                targetPtr = Marshal.StringToCoTaskMemUni(target);
                userPtr = Marshal.StringToCoTaskMemUni(userName ?? String.Empty);
                blobPtr = Marshal.AllocCoTaskMem(secretBytes.Length);
                Marshal.Copy(secretBytes, 0, blobPtr, secretBytes.Length);

                CREDENTIAL credential = new CREDENTIAL
                {
                    Type = CRED_TYPE_GENERIC,
                    TargetName = targetPtr,
                    CredentialBlobSize = (UInt32)secretBytes.Length,
                    CredentialBlob = blobPtr,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    UserName = userPtr
                };

                if (!CredWrite(ref credential, 0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                if (blobPtr != IntPtr.Zero)
                {
                    byte[] zeros = new byte[secretBytes.Length];
                    Marshal.Copy(zeros, 0, blobPtr, zeros.Length);
                    Marshal.FreeCoTaskMem(blobPtr);
                }
                if (targetPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(targetPtr);
                if (userPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(userPtr);
                Array.Clear(secretBytes, 0, secretBytes.Length);
            }
        }

        public static string Read(string target)
        {
            IntPtr credentialPtr;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out credentialPtr))
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_NOT_FOUND) return null;
                throw new Win32Exception(error);
            }

            try
            {
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(credentialPtr, typeof(CREDENTIAL));
                if (credential.CredentialBlobSize == 0 || credential.CredentialBlob == IntPtr.Zero) return String.Empty;

                byte[] bytes = new byte[credential.CredentialBlobSize];
                try
                {
                    Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
                    return Encoding.UTF8.GetString(bytes);
                }
                finally
                {
                    Array.Clear(bytes, 0, bytes.Length);
                }
            }
            finally
            {
                CredFree(credentialPtr);
            }
        }

        public static bool Delete(string target)
        {
            if (CredDelete(target, CRED_TYPE_GENERIC, 0)) return true;
            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_NOT_FOUND) return false;
            throw new Win32Exception(error);
        }
    }
}
'@
}

function Get-StatsToken {
    [CmdletBinding()]
    param()

    return [QuickkNastyyProfileStats.CredentialManager]::Read($script:StatsCredentialTarget)
}

function Set-StatsToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Token
    )

    $bstr = [IntPtr]::Zero
    $plain = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ([string]::IsNullOrWhiteSpace($plain)) {
            throw 'Token cannot be empty.'
        }
        [QuickkNastyyProfileStats.CredentialManager]::Write($script:StatsCredentialTarget, $script:StatsCredentialUser, $plain)
    }
    finally {
        $plain = $null
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Remove-StatsToken {
    [CmdletBinding()]
    param()

    return [QuickkNastyyProfileStats.CredentialManager]::Delete($script:StatsCredentialTarget)
}
