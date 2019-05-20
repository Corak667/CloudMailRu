unit CMLHTTP;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, ChunkedFileStream, SplitFile, Settings, PLUGIN_Types, CMLTypes, IdStack, IdCookieManager, IdIOHandler, IdIOHandlerSocket, IdIOHandlerStack, IdSSL, IdSSLOpenSSL, IdBaseComponent, IdComponent, IdTCPConnection, IdTCPClient, IdSocks, IdHTTP, IdAuthentication, IdIOHandlerStream, IdInterceptThrottler, IdCookie, IdMultipartFormData;

type

	TCloudMailRuHTTP = class
	private
		{VARIABLES}
		HTTP: TIdHTTP;
		SSL: TIdSSLIOHandlerSocketOpenSSL;
		Cookie: TIdCookieManager;
		Socks: TIdSocksInfo;
		Throttle: TIdInterceptThrottler;
		Settings: TConnectionSettings;

		ExternalProgressProc: TProgressHandler;
		ExternalLogProc: TLogHandler;

		{PROCEDURES}
		procedure Log(LogLevel, MsgType: integer; LogString: WideString);
	public
		{VARIABLES}
		ExternalSourceName: PWideChar;
		ExternalTargetName: PWideChar;
		{PROPERTIES}
		Property Options: TConnectionSettings read Settings;
		{CONSTRUCTOR/DESTRUCTOR}
		constructor Create(Settings: TConnectionSettings; ExternalProgressProc: TProgressHandler = nil; ExternalLogProc: TLogHandler = nil);
		destructor Destroy; override;
		{MAIN ROUTINES}
		function GetPage(URL: WideString; var Answer: WideString; var ProgressEnabled: Boolean): Boolean; //���� ProgressEnabled - �������� ���������� onWork, ���������� ProgressEnabled=false ��� ������
		function GetFile(URL: WideString; FileStream: TStream; LogErrors: Boolean = true): integer;

		function PostForm(URL: WideString; PostDataString: WideString; var Answer: WideString; ContentType: WideString = 'application/x-www-form-urlencoded'; LogErrors: Boolean = true; ProgressEnabled: Boolean = true): Boolean; //������� ������ � ��������� ���������� ������.
		function PostMultipart(URL: WideString; Params: TDictionary<WideString, WideString>; var Answer: WideString): Boolean;
		function PostFile(URL: WideString; FileName: WideString; FileStream: TStream; var Answer: WideString): integer; overload; //������� ������ ������ ��� �����

		function Post(URL: WideString; PostData, ResultData: TStringStream; UnderstandResponseCode: Boolean = false; ContentType: WideString = ''; LogErrors: Boolean = true; ProgressEnabled: Boolean = true): integer; overload; //������� �������������� ������, ����� ������
		function Post(URL: WideString; var PostData: TIdMultiPartFormDataStream; ResultData: TStringStream): integer; overload; //TIdMultiPartFormDataStream should be passed via var
		function ExceptionHandler(E: Exception; URL: WideString; HTTPMethod: integer = HTTP_METHOD_POST; LogErrors: Boolean = true): integer;

		procedure Progress(ASender: TObject; AWorkMode: TWorkMode; AWorkCount: int64);
	end;

implementation

{TCloudMailRuHTTP}

constructor TCloudMailRuHTTP.Create(Settings: TConnectionSettings; ExternalProgressProc: TProgressHandler = nil; ExternalLogProc: TLogHandler = nil);
begin
	self.ExternalProgressProc := ExternalProgressProc;
	self.ExternalLogProc := ExternalLogProc;
	self.Cookie := TIdCookieManager.Create();
	self.Throttle := TIdInterceptThrottler.Create();
	SSL := TIdSSLIOHandlerSocketOpenSSL.Create();
	SSL.SSLOptions.SSLVersions := [sslvSSLv23];
	HTTP := TIdHTTP.Create();

	if Settings.ProxySettings.ProxyType in SocksProxyTypes then //SOCKS proxy initialization
	begin
		self.Socks := TIdSocksInfo.Create();
		self.Socks.Host := Settings.ProxySettings.Server;
		self.Socks.Port := Settings.ProxySettings.Port;
		if Settings.ProxySettings.user <> EmptyWideStr then
		begin
			self.Socks.Authentication := saUsernamePassword;
			self.Socks.Username := Settings.ProxySettings.user;
			self.Socks.password := Settings.ProxySettings.password;
		end
		else
			self.Socks.Authentication := saNoAuthentication;

		case Settings.ProxySettings.ProxyType of
			ProxySocks5:
				Socks.Version := svSocks5;
			ProxySocks4:
				Socks.Version := svSocks4;
		end;
		self.Socks.Enabled := true;
	end;

	if (Settings.ProxySettings.ProxyType in SocksProxyTypes) and (self.Socks.Enabled) then
		SSL.TransparentProxy := self.Socks;
	if Settings.ProxySettings.ProxyType = ProxyHTTP then
	begin
		HTTP.ProxyParams.ProxyServer := Settings.ProxySettings.Server;
		HTTP.ProxyParams.ProxyPort := Settings.ProxySettings.Port;
		if Settings.ProxySettings.user <> EmptyWideStr then
		begin
			HTTP.ProxyParams.BasicAuthentication := true;
			HTTP.ProxyParams.ProxyUsername := Settings.ProxySettings.user;
			HTTP.ProxyParams.ProxyPassword := Settings.ProxySettings.password;
		end
	end;
	HTTP.CookieManager := Cookie;
	HTTP.IOHandler := SSL;
	HTTP.AllowCookies := true;
	HTTP.HTTPOptions := [hoForceEncodeParams, hoNoParseMetaHTTPEquiv, hoKeepOrigProtocol, hoTreat302Like303];
	HTTP.HandleRedirects := true;
	if (Settings.SocketTimeout < 0) then
	begin
		HTTP.ConnectTimeout := Settings.SocketTimeout;
		HTTP.ReadTimeout := Settings.SocketTimeout;
	end;
	if (Settings.UploadBPS > 0) or (Settings.DownloadBPS > 0) then
	begin
		self.Throttle.RecvBitsPerSec := Settings.DownloadBPS;
		self.Throttle.SendBitsPerSec := Settings.UploadBPS;

	end;

	HTTP.Request.UserAgent := 'Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.57 Safari/537.17/TCWFX(' + PlatformX + ')';
	HTTP.Request.Connection := EmptyWideStr;
end;

destructor TCloudMailRuHTTP.Destroy;
begin
	HTTP.free;
	SSL.free;
	if Assigned(self.Cookie) then
		self.Cookie.free;
	if Assigned(self.Throttle) then
		self.Throttle.free;
	if Assigned(self.Socks) then
		self.Socks.free;
	inherited;
end;

function TCloudMailRuHTTP.GetFile(URL: WideString; FileStream: TStream; LogErrors: Boolean): integer;
begin
	result := FS_FILE_OK;
	try
		HTTP.Intercept := Throttle;
		HTTP.Request.ContentType := 'application/octet-stream';
		HTTP.Response.KeepAlive := true;
		HTTP.OnWork := self.Progress;
		HTTP.Get(URL, FileStream);
		if (HTTP.RedirectCount = HTTP.RedirectMaximum) and (FileStream.size = 0) then
		begin
			result := FS_FILE_NOTSUPPORTED;
		end;
	except
		on E: Exception do
		begin
			result := self.ExceptionHandler(E, URL, HTTP_METHOD_GET, LogErrors);
		end;
	end;
end;

function TCloudMailRuHTTP.GetPage(URL: WideString; var Answer: WideString; var ProgressEnabled: Boolean): Boolean;
begin
	result := false;
	try
		if ProgressEnabled then
			HTTP.OnWork := self.Progress//����� ��������� ���� � ����������� �������� ��������� ������ ��������� � ������ ��������, ������� �� ����� �� ������
		else
			HTTP.OnWork := nil;
		Answer := HTTP.Get(URL);

		result := Answer <> EmptyWideStr;
	Except
		on E: Exception do
		begin
			case self.ExceptionHandler(E, URL) of
				CLOUD_OPERATION_CANCELLED:
					begin
						ProgressEnabled := false; //�������� �� ������
					end;
				CLOUD_OPERATION_FAILED:
					begin
						case HTTP.ResponseCode of
							HTTP_ERROR_BAD_REQUEST, HTTP_ERROR_OVERQUOTA: //recoverable errors
								begin
									//Answer := (E as EIdHTTPProtocolException).ErrorMessage; //TODO: ����� ��������������, ��������� ��� �� json
								end;
						end;
					end;
			end;
		end;

	end;
end;

function TCloudMailRuHTTP.Post(URL: WideString; PostData, ResultData: TStringStream; UnderstandResponseCode: Boolean; ContentType: WideString; LogErrors, ProgressEnabled: Boolean): integer;
begin
	result := CLOUD_OPERATION_OK;
	ResultData.Position := 0;
	try
		if ContentType <> EmptyWideStr then
			HTTP.Request.ContentType := ContentType;
		if ProgressEnabled then
			HTTP.OnWork := self.Progress
		else
			HTTP.OnWork := nil;
		HTTP.Post(URL, PostData, ResultData);

	except
		on E: Exception do
		begin
			result := self.ExceptionHandler(E, URL, HTTP_METHOD_POST, LogErrors);
			if UnderstandResponseCode and (E is EIdHTTPProtocolException) then
			begin
				case HTTP.ResponseCode of
					HTTP_ERROR_BAD_REQUEST, HTTP_ERROR_OVERQUOTA: //recoverable errors
						begin
							ResultData.WriteString((E as EIdHTTPProtocolException).ErrorMessage);
							result := CLOUD_OPERATION_OK;
						end;
				end;
			end;

		end;
	end;
end;

function TCloudMailRuHTTP.Post(URL: WideString; var PostData: TIdMultiPartFormDataStream; ResultData: TStringStream): integer;
begin
	result := CLOUD_OPERATION_OK;
	ResultData.Position := 0;
	try
		HTTP.Intercept := Throttle;
		HTTP.OnWork := self.Progress;
		HTTP.Post(URL, PostData, ResultData);
	except
		On E: Exception do
		begin
			result := self.ExceptionHandler(E, URL);
		end;
	end;
end;

function TCloudMailRuHTTP.PostFile(URL, FileName: WideString; FileStream: TStream; var Answer: WideString): integer;
var
	PostData: TIdMultiPartFormDataStream;
	ResultStream: TStringStream;

begin
	ResultStream := TStringStream.Create;
	PostData := TIdMultiPartFormDataStream.Create;
	PostData.AddFormField('file', 'application/octet-stream', EmptyWideStr, FileStream, FileName);
	result := self.Post(URL, PostData, ResultStream);
	Answer := ResultStream.DataString;

	ResultStream.free;
	PostData.free;
end;

function TCloudMailRuHTTP.PostForm(URL, PostDataString: WideString; var Answer: WideString; ContentType: WideString; LogErrors, ProgressEnabled: Boolean): Boolean;
var
	ResultStream, PostData: TStringStream;
	PostResult: integer;
begin
	ResultStream := TStringStream.Create;
	PostData := TStringStream.Create(PostDataString, TEncoding.UTF8);

	PostResult := self.Post(URL, PostData, ResultStream, true, ContentType, LogErrors, ProgressEnabled);
	result := PostResult = CLOUD_OPERATION_OK;
	Answer := ResultStream.DataString;

	ResultStream.free;
	PostData.free;
end;

function TCloudMailRuHTTP.PostMultipart(URL: WideString; Params: TDictionary<WideString, WideString>; var Answer: WideString): Boolean;
var
	ResultStream: TStringStream;
	PostData: TIdMultiPartFormDataStream;
	ParamItem: TPair<WideString, WideString>;
	PostResult: integer;
begin

	ResultStream := TStringStream.Create;

	PostData := TIdMultiPartFormDataStream.Create;
	for ParamItem in Params do
		PostData.AddFormField(ParamItem.Key, ParamItem.Value);

	PostResult := self.Post(URL, PostData, ResultStream);
	result := PostResult = CLOUD_OPERATION_OK;
	Answer := ResultStream.DataString;

	ResultStream.free;
	PostData.free;
end;

procedure TCloudMailRuHTTP.Progress(ASender: TObject; AWorkMode: TWorkMode; AWorkCount: int64);
var
	ContentLength: int64;
	Percent: integer;
begin
	HTTP := TIdHTTP(ASender);
	if AWorkMode = wmRead then
		ContentLength := HTTP.Response.ContentLength
	else
		ContentLength := HTTP.Request.ContentLength; //������� ������ ������������ ������ � ����������� �� ����, ���������� ��� ��� ��������
	if (Pos('chunked', LowerCase(HTTP.Response.TransferEncoding)) = 0) and (ContentLength > 0) then
	begin
		Percent := 100 * AWorkCount div ContentLength;
		if Assigned(ExternalProgressProc) and (ExternalProgressProc(self.ExternalSourceName, self.ExternalTargetName, Percent) = 1) then {��� �������� nil �������� ��������� ���������� ��������}
			abort;
	end;
end;

procedure TCloudMailRuHTTP.Log(LogLevel, MsgType: integer; LogString: WideString);
begin
	if Assigned(ExternalLogProc) then
		ExternalLogProc(LogLevel, MsgType, PWideChar(LogString));
end;

function TCloudMailRuHTTP.ExceptionHandler(E: Exception; URL: WideString; HTTPMethod: integer; LogErrors: Boolean): integer;
var
	method_string: WideString; //� ����������� �� ������ ��������� ������� �������� ����� ���������
begin
	if HTTPMethod = HTTP_METHOD_GET then
	begin
		method_string := '��������� ������ � ������ ';
		result := FS_FILE_READERROR; //��� GetFile, GetForm �� ���������� ��� ������
	end else begin
		method_string := '�������� ������ �� ����� ';
		result := CLOUD_OPERATION_FAILED; //��� ���� Post-��������
	end;

	if E is EAbort then
	begin
		result := CLOUD_OPERATION_CANCELLED;
	end else if LogErrors then //��������� ������ ������ ����� ����� ������ ��� ����������� - ��� ������� ��� �������
	begin
		if E is EIdHTTPProtocolException then
			Log(LogLevelError, MSGTYPE_IMPORTANTERROR, E.ClassName + ' ������ � ����������: ' + E.Message + ' ��� ' + method_string + URL + ', ����� �������: ' + (E as EIdHTTPProtocolException).ErrorMessage)
		else if E is EIdSocketerror then
			Log(LogLevelError, MSGTYPE_IMPORTANTERROR, E.ClassName + ' ������ ����: ' + E.Message + ' ��� ' + method_string + URL)
		else
			Log(LogLevelError, MSGTYPE_IMPORTANTERROR, E.ClassName + ' ������ � ����������: ' + E.Message + ' ��� ' + method_string + URL);

	end;
end;

end.
