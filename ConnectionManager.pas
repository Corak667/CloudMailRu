unit ConnectionManager;

{ ������������ ���������� �������������� ������������ ��� ������������� ���������� ���������������. ��� ������ ��������� ������ ����������� ��������,
	��� ����������� - �������� ��� ���������. }

interface

uses CloudMailRu, MRC_Helper, windows, controls, PLUGIN_Types,
	AskPassword;

type

	TNamedConnection = record
		Name: WideString;
		Connection: TCloudMailRu;
	end;

	TConnectionManager = class
	private
		Connections: array of TNamedConnection;
		IniFileName: WideString;
		Proxy: TProxySettings;

		PluginNum: integer;

		MyProgressProc: TProgressProcW;
		MyLogProc: TLogProcW;

		function ConnectionExists(connectionName: WideString): integer; // ��������� ������������� �����������
		function new(connectionName: WideString): integer; // ��������� ����������� � ���
		function GetMyPasswordNow(var AccountSettings: TAccountSettings): boolean; // �������� ������ �� �����, �� ������������ ��������� ��� ����������� ������ ����

	public
		CryptoNum: integer;
		MyCryptProc: TCryptProcW;
		constructor Create(IniFileName: WideString; PluginNum: integer; MyProgressProc: TProgressProcW; MyLogProc: TLogProcW; ProxySettings: TProxySettings);
		destructor Destroy(); override;
		function get(connectionName: WideString; var OperationResult: integer; doInit: boolean = true): TCloudMailRu; // ���������� ������� ���������� �� �����
		function set_(connectionName: WideString; cloud: TCloudMailRu): boolean;
		function init(connectionName: WideString; ProxySettings: TProxySettings): integer; // �������������� ����������� �� ��� �����, ���������� ��� ���������
		function free(connectionName: WideString): integer; // ����������� ����������� �� ��� �����, ���������� ��� ���������
		function freeAll: integer; // ����������� ��� �����������
		function initialized(connectionName: WideString): boolean; // ���������, ���������������� �� �����������

	end;

implementation

{ TConnectionManager }
constructor TConnectionManager.Create(IniFileName: WideString; PluginNum: integer; MyProgressProc: TProgressProcW; MyLogProc: TLogProcW; ProxySettings: TProxySettings);
begin
	SetLength(Connections, 0);
	self.IniFileName := IniFileName;
	self.PluginNum := PluginNum;
	self.MyProgressProc := MyProgressProc;
	self.MyLogProc := MyLogProc;
	self.Proxy := ProxySettings;
end;

destructor TConnectionManager.Destroy;
begin
	freeAll();
end;

function TConnectionManager.get(connectionName: WideString; var OperationResult: integer; doInit: boolean = true): TCloudMailRu;
var
	ConnectionIndex: integer;
begin
	ConnectionIndex := ConnectionExists(connectionName);
	if ConnectionIndex <> -1 then
	begin
		result := Connections[ConnectionIndex].Connection;
	end else begin
		result := Connections[new(connectionName)].Connection;
	end;
	if (doInit) then
	begin
		OperationResult := CLOUD_OPERATION_OK;
		if not initialized(connectionName) then OperationResult := init(connectionName,self.Proxy);
		if (OperationResult = CLOUD_OPERATION_OK) then result := get(connectionName, OperationResult, false);
	end;
	{ ���� ������������ �� �������, ��� ������� ������ ����� ���������� ���������� ���������, �� ��� AV }
end;

function TConnectionManager.set_(connectionName: WideString; cloud: TCloudMailRu): boolean;
var
	ConnectionIndex: integer;
begin
	ConnectionIndex := ConnectionExists(connectionName);
	if ConnectionIndex = -1 then exit(false);
	Connections[ConnectionIndex].Connection := cloud;
	result := true;
end;

function TConnectionManager.init(connectionName: WideString; ProxySettings: TProxySettings): integer;
var
	cloud: TCloudMailRu;
	AccountSettings: TAccountSettings;
begin
	result := CLOUD_OPERATION_OK;
	AccountSettings := GetAccountSettingsFromIniFile(IniFileName, connectionName);

	if not GetMyPasswordNow(AccountSettings) then exit(CLOUD_OPERATION_ERROR_STATUS_UNKNOWN); // INVALID_HANDLE_VALUE

	MyLogProc(PluginNum, MSGTYPE_CONNECT, PWideChar('CONNECT ' + AccountSettings.email));

	cloud := TCloudMailRu.Create(AccountSettings.user, AccountSettings.domain, AccountSettings.password, self.Proxy, MyProgressProc, PluginNum, MyLogProc);
	if not set_(connectionName, cloud) then exit(CLOUD_OPERATION_ERROR_STATUS_UNKNOWN); // INVALID_HANDLE_VALUE

	if not(get(connectionName, result, false).login()) then free(connectionName);

	// cloud.Destroy;
end;

function TConnectionManager.initialized(connectionName: WideString): boolean;
var
	dump: integer;
begin
	result := Assigned(get(connectionName, dump, false));
end;

function TConnectionManager.new(connectionName: WideString): integer;
begin
	SetLength(Connections, Length(Connections) + 1);
	Connections[Length(Connections) - 1].Name := connectionName;
	result := Length(Connections) - 1;
end;

function TConnectionManager.ConnectionExists(connectionName: WideString): integer;
var
	I: integer;
begin
	result := -1;

	for I := 0 to Length(Connections) - 1 do
	begin
		if Connections[I].Name = connectionName then exit(I);
	end;
end;

function TConnectionManager.free(connectionName: WideString): integer;
begin
	result := CLOUD_OPERATION_OK;
	get(connectionName, result, false).free;
	set_(connectionName, nil);
end;

function TConnectionManager.freeAll: integer;
var
	I: integer;
begin
	result := CLOUD_OPERATION_OK;

	for I := 0 to Length(Connections) - 1 do
	begin
		if initialized(Connections[I].Name) then
		begin
			Connections[I].Connection.free;
			set_(Connections[I].Name, nil);
		end;
	end;
	SetLength(Connections, 0);

end;

function TConnectionManager.GetMyPasswordNow(var AccountSettings: TAccountSettings): boolean;
var
	CryptResult: integer;
	AskResult: integer;
	TmpString: WideString;
	buf: PWideChar;
begin
	if AccountSettings.use_tc_password_manager then
	begin // ������ ������ ������� �� TC
		GetMem(buf, 1024);
		CryptResult := MyCryptProc(PluginNum, CryptoNum, FS_CRYPT_LOAD_PASSWORD_NO_UI, PWideChar(AccountSettings.Name), buf, 1024); // �������� ����� ������ ��-������
		if CryptResult = FS_FILE_NOTFOUND then
		begin
			MyLogProc(PluginNum, msgtype_details, PWideChar('No master password entered yet'));
			CryptResult := MyCryptProc(PluginNum, CryptoNum, FS_CRYPT_LOAD_PASSWORD, PWideChar(AccountSettings.Name), buf, 1024);
		end;
		if CryptResult = FS_FILE_OK then // ������� �������� ������
		begin
			AccountSettings.password := buf;
			// Result := true;
		end;
		if CryptResult = FS_FILE_NOTSUPPORTED then // ������������ ������� ���� �������� ������
		begin
			MyLogProc(PluginNum, msgtype_importanterror, PWideChar('CryptProc returns error: Decrypt failed'));
		end;
		if CryptResult = FS_FILE_READERROR then
		begin
			MyLogProc(PluginNum, msgtype_importanterror, PWideChar('CryptProc returns error: Password not found in password store'));
		end;
		FreeMemory(buf);
	end; // else // ������ �� ������, ������ ��� ������ ���� � ���������� (���� � �������� ���� �� ��������)

	if AccountSettings.password = '' then // �� ������ ���, �� � ��������, �� � ������
	begin
		AskResult := TAskPasswordForm.AskPassword(FindTCWindow, AccountSettings.Name, AccountSettings.password, AccountSettings.use_tc_password_manager);
		if AskResult <> mrOK then
		begin // �� ������� ������ � �������
			exit(false); // ���������� ������� ������
		end else begin
			if AccountSettings.use_tc_password_manager then
			begin
				case MyCryptProc(PluginNum, CryptoNum, FS_CRYPT_SAVE_PASSWORD, PWideChar(AccountSettings.Name), PWideChar(AccountSettings.password), SizeOf(AccountSettings.password)) of
					FS_FILE_OK:
						begin // TC ������ ������, �������� � ������� �������
							MyLogProc(PluginNum, msgtype_details, PWideChar('Password saved in TC password manager'));
							TmpString := AccountSettings.password;
							AccountSettings.password := '';
							SetAccountSettingsToIniFile(IniFileName, AccountSettings);
							AccountSettings.password := TmpString;
						end;
					FS_FILE_NOTSUPPORTED: // ���������� �� ����������
						begin
							MyLogProc(PluginNum, msgtype_importanterror, PWideChar('CryptProc returns error: Encrypt failed'));
						end;
					FS_FILE_WRITEERROR: // ���������� ����� �� ����������
						begin
							MyLogProc(PluginNum, msgtype_importanterror, PWideChar('Password NOT saved: Could not write password to password store'));
						end;
					FS_FILE_NOTFOUND: // �� ������ ������-������
						begin
							MyLogProc(PluginNum, msgtype_importanterror, PWideChar('Password NOT saved: No master password entered yet'));
						end;
					// ������ ����� �� ������, ��� ������ �� �� �������� - �� ����� ���� ����� � �������
				end;
			end;
			result := true;
		end;
	end
	else result := true; // ������ ���� �� �������� ��������
end;

end.
