# Settings for join-network.ps1, install.ps1, uninstall.ps1 and the scripts.
# No addresses or keys here: this PC's private address is discovered from
# Tailscale, CogyServer's is given to install.ps1 with -AllowFrom, and the join
# key is passed on the command line.
@{
    # Project
    Name               = 'Vera'
    Role               = "CogyServer's verifier"

    # Windows services and firewall rule group.
    # ServiceName runs Vera's own code (vera\vera.py) on Port; it uses the
    # model server (OVMS), which listens on 127.0.0.1:OvmsPort only.
    ServiceName        = 'CogyVera'
    ServiceDisplayName = 'Cogy Vera'
    OvmsServiceName    = 'CogyVeraModel'
    OvmsDisplayName    = 'Cogy Vera model server (OVMS)'
    OvmsPort           = 18811
    FirewallGroup      = 'Cogy Vera'

    # Install location. Default: %ProgramData%\CogyVera
    InstallDirName     = 'CogyVera'

    # API
    Port               = 8811

    # OpenVINO Model Server (Windows build without Python)
    OvmsVersion        = '2026.4.0'
    OvmsZip            = 'ovms_windows_2026.4.0_python_off.zip'
    OvmsSha256         = '46d03114c97abfe05f2c5a8fde772c655aeef541ee254c23f402f81a616474e3'

    # Model
    ModelId            = 'OpenVINO/Qwen3.6-35B-A3B-int4-ov'
    ContextLength      = 65536
    MaxTokens          = 4000              # per verdict

    # Python for vera\vera.py (embeddable build, standard library only)
    PythonVersion      = '3.12.10'
    PythonZipUrl       = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
    PythonSha256       = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'

    # WinSW runs vera.py as a Windows service (start at boot, restart on a crash)
    WinSWUrl           = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
    WinSWSha256        = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'

    # Tailscale (installed by join-network.ps1 when missing)
    TailscaleMsiUrl    = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
}
