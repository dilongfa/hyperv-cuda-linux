# Windows GPU-P Configuration Script for Hyper-V
# Run as Administrator in PowerShell

param(
  [Parameter(Mandatory, Position=0)]
  [ValidateNotNullorEmpty()][string]$VMName,
  
  [Parameter(Mandatory, Position=1)]
  [ValidateNotNullorEmpty()][string]$VMUser,
  
  [Parameter(Mandatory, Position=2)]
  [ValidateNotNullorEmpty()][string]$VMIp,

  [switch]$Help
)

function Show-Log {
    param([string]$Message)
    Write-Host "$Message" -F Green
}

function Show-Info {
    param([string]$Message)
    Write-Host "INFO: $Message" -F Cyan
}

function Show-Warning {
    param([string]$Message)
    Write-Host "WARNING: $Message" -F Yellow
}

function Show-Error {
    param([string]$Message)
    Write-Host "ERROR: $Message" -F Red
    exit 1
}

function Write-Header {
    param([string]$Title)
    Write-Host "================================" -F Cyan
    Write-Host $Title -F Cyan
    Write-Host "================================" -F Cyan
}

function Show-Usage {
Write-Host @"
Windows GPU-P Configuration Script for Hyper-V

USAGE:
    .\setup-gpup.ps1 -VMName <TEN_VM> [-VMUser <USER>] [-VMIp <IP>] [-Help]

PARAMETERS:
    -VMName         Tên máy ảo Hyper-V (bắt buộc)
    -VMUser         Username trên Linux VM (cho copy drivers)
    -VMIp           IP của Linux VM (cho copy drivers)
    -Help           Hiển thị trợ giúp này

EXAMPLES:
    .\setup-gpup.ps1 -VMName "Debian12" -VMUser "debian" -VMIp "192.168.1.100"

    # Hoặc
    .\setup-gpup.ps1 "Debian12" "debian" "192.168.1.100"

YÊU CẦU:
    - Windows 11 22H2+ hoặc Windows 10 21H2+
    - Hyper-V enabled
    - VM phải là Generation 2
    - GPU hỗ trợ paravirtualization
    - PowerShell chạy với quyền Administrator
    - SSH phải được cài đặt trên cả Windows và VM
"@
}

function Test-Prerequisites {
  Write-Header "BƯỚC 1: KIỂM TRA CÁC ĐIỀU KIỆN BẮT BUỘC"
  # Check Administrator
  $Principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (!$Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Show-Error "Script phải chạy với quyền Administrator!"
  }

  # Check Hyper-V
  if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State -ne "Enabled") {
    Show-Error "Hyper-V chưa được bật. Hãy bật Hyper-V và khởi động lại."
  }

  # Check OpenSSH.Client 
  if ((Get-WindowsCapability -Online -Name "OpenSSH.Client").State -ne "Installed") {
    Show-Error "OpenSSH.Client không có. Hãy cài đặt OpenSSH cho Windows"
  }
  Show-Log "Mọi thứ OK!"
}

function Set-VMGpu {
  Write-Header "BƯỚC 2: CẤU HÌNH GPU-P CHO MÁY ẢO"
    
  $GPU = (Get-VMHostPartitionableGpu)[0]
  if (!$GPU) {
    Show-Error "Không tìm thấy GPU hỗ trợ partitioning!"
  }

  $VM = Get-VM $VMName -EA Silent

  # Kiểm tra VM
  if (!$VM) {
    Show-Error "Máy ảo $VMName không tồn tại"
  }

  # Check VM generation
  if ($VM.Generation -ne 2) {
    Show-Error "VM phải là Generation 2 để hỗ trợ GPU-P"
  }
  
  # Stop VM if running
  if ($VM.State -ne "Off") {
    Show-Log "Đang tắt VM..."
    Stop-VM $VMName -Force
    Start-Sleep -Seconds 5
  }

  Show-Log "Thêm GPU-P adapter..."
  # Remove existing GPU-P adapter
  Remove-VMGpuPartitionAdapter $VMName -EA Silent
  # Add GPU-P adapter
  Add-VMGpuPartitionAdapter $VMName

  # Configure GPU partition settings
  # https://docs.nvidia.com/vgpu/latest/pdf/grid-vgpu-user-guide.pdf (page 29-30)
  Show-Log "Cấu hình GPU partition..."
  Set-VMGpuPartitionAdapter $VMName `
    -MinPartitionVRAM $GPU.MinPartitionVRAM `
    -MaxPartitionVRAM $GPU.MaxPartitionVRAM `
    -OptimalPartitionVRAM $GPU.OptimalPartitionVRAM `
    -MinPartitionEncode $GPU.MinPartitionEncode `
    -MaxPartitionEncode $GPU.MaxPartitionEncode `
    -OptimalPartitionEncode $GPU.OptimalPartitionEncode `
    -MinPartitionDecode $GPU.MinPartitionDecode `
    -MaxPartitionDecode $GPU.MaxPartitionDecode `
    -OptimalPartitionDecode $GPU.OptimalPartitionDecode `
    -MinPartitionCompute $GPU.MinPartitionCompute `
    -MaxPartitionCompute $GPU.MaxPartitionCompute `
    -OptimalPartitionCompute $GPU.OptimalPartitionCompute

  Set-VM $VMName -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB

  Set-VMMemory $VMName -DynamicMemoryEnabled $false
  Set-VMFirmware $VMName -EnableSecureBoot Off
  Set-VM $VMName -CheckpointType Disabled -AutomaticStopAction TurnOff

  Show-Log "Cấu hình GPU-P cho máy ảo thành công!"
}

function Copy-Drivers {
  Write-Header "BƯỚC 4: COPY DRIVERS VÀO MÁY ẢO"

  # Test SSH connection
  Show-Log "Kiểm tra kết nối SSH..."
  if (!(Test-Connection $VMIp -TcpPort 22 -Timeout 2 -Quiet)) {
      Show-Error "SSH connection Error"
  }
  Show-Log "SSH connection OK"
  
  if (!(Get-Command ssh -EA Silent)) {
      Show-Error "Lệnh ssh không tồn tại. Vui lòng kiểm tra lại đường dẫn hoặc cài đặt OpenSSH Client"
  }

  if (!(Test-Path "C:\Program Files\WSL\lib")) {
    Show-Log "Đang cài đặt WSL..."
    wsl --update
  }

  Show-Log "Tạo thư mục wsl/drivers và wsl/lib trên máy ảo qua SSH"
  ssh ${VMUser}@${VMIp} "mkdir -p ~/wsl/{drivers,lib}"

  (Get-CimInstance Win32_VideoController).InstalledDisplayDrivers.Split(",") | Get-Unique | ForEach-Object {
    $path = Split-Path $_ -Parent
    if ($path -match "\\nv\w") {
      $dir = Split-Path $path -Leaf
      Show-Log "Đang sao chép các tệp vào thư mục ~/wsl/drivers/$dir"
      scp "$path\*.so*" "$path\*.bin" ${VMUser}@${VMIp}:~/wsl/drivers/${dir}
    }
  }

  Show-Log "Đang sao chép các tệp vào thư mục ~/wsl/lib"
  scp "C:\Windows\System32\lxss\lib\*" "C:\Program Files\WSL\lib\*" ${VMUser}@${VMIp}:~/wsl/lib

  Show-Log "✓ Drivers copied successfully"
}

function Restart-VM {
  Write-Header "BƯỚC 3: KHỞI ĐỘNG LẠI MÁY ẢO"

  Start-VM $VMName

  Show-Log "Đang khởi động $VMName"
  Start-Sleep 1
  do {
      Write-Host "." -NoNewline
      Start-Sleep 1
      $heartbeat = (Get-VM $VMName).Heartbeat
  } while ($heartbeat -ne 'Ok' -and $heartbeat -ne 'OkApplicationsUnknown')

  Show-Log "`n$VMName đã khởi động xong`n"
}

function Show-NextSteps {
    Write-Header "BƯỚC 5: THỰC HIỆN CÁC BƯỚC SAU TRÊN MÁY ẢO"
    
    Write-Host ""
    Write-Host "1. Đăng nhập vào máy ảo" -F Yellow
    Write-Host ""
    Write-Host "2. Tải và chạy script cài đặt:" -F Yellow
    Write-Host "   curl -fsSL https://raw.githubusercontent.com/dilongfa/hyperv-cuda-linux/install.sh | sudo bash -es"
    Write-Host ""
    Write-Host "3. Khởi động lại VM sau khi cài đặt:" -F Yellow
    Write-Host "   sudo reboot"
    Write-Host ""
    Write-Host "4. Kiểm tra GPU:" -F Yellow
    Write-Host "   nvidia-smi"
    Write-Host "   nvcc --version"
    Write-Host ""
}

# Main execution
if ($Help) {
    Show-Usage
    exit 0
}

Write-Header "WINDOWS GPU-P SETUP FOR HYPER-V"

Test-Prerequisites
Set-VMGpu
Restart-VM
Copy-Drivers
Show-NextSteps

Show-Log "✓ Windows-side setup completed!"