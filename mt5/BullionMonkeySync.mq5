//+------------------------------------------------------------------+
//| BullionMonkeySync.mq5                                            |
//| Sends closed trades, open positions and the balance to a secret  |
//| GitHub Gist, which the Bullion Monkey app reads.                 |
//| Setup: Tools > Options > Expert Advisors > "Allow WebRequest for |
//| listed URL" and add https://api.github.com                       |
//+------------------------------------------------------------------+
#property copyright "Bullion Monkey"
#property version   "1.10"

input string GitHubToken = "";   // GitHub token (classic, only "gist" scope)
input string GistId      = "";   // leave empty: the EA creates a secret gist
input int    DaysBack    = 365;  // how many days of history to send
input int    SyncSeconds = 60;   // check interval in seconds

#define GIST_FILE "bullion-monkey.json"
#define ID_FILE   "bullion_monkey_gist.txt"
#define API       "https://api.github.com/gists"

string g_gist = "";
string g_last = "";     // last uploaded trade/balance payload, to skip unchanged uploads
bool   g_dirty = true;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringLen(GitHubToken) < 10)
     {
      Alert("Bullion Monkey: GitHub-Token fehlt (Eingabe GitHubToken).");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_gist = GistId;
   if(g_gist == "")
      g_gist = ReadSavedId();
   EventSetTimer(SyncSeconds < 15 ? 15 : SyncSeconds);
   Sync();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() { Sync(); }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      g_dirty = true;
      Sync();
     }
  }

//+------------------------------------------------------------------+
//| Collect closed positions and upload them                         |
//+------------------------------------------------------------------+
void Sync()
  {
   string payload = BuildPayload();
   if(payload == "")
      return;
   // the timestamp lives outside the comparison, so identical data is not re-uploaded every minute
   if(payload == g_last && !g_dirty)
      return;
   string json = "{\"updatedAt\":\"" + IsoUtc(TimeGMT()) + "\"," + payload + "}";
   if(Upload(json))
     {
      g_last = payload;
      g_dirty = false;
     }
  }

string BuildPayload()
  {
   datetime to = TimeCurrent() + 86400;
   datetime from = TimeCurrent() - (datetime)DaysBack * 86400;
   if(!HistorySelect(from, to))
      return "";

   long     pid[];      // position id
   string   sym[];
   double   pnl[], volIn[], entry[], sl[];
   datetime closeT[], openT[];
   int      side[];     // 0 buy, 1 sell
   bool     closed[];
   int n = 0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;   // skip deposits, credit, etc.
      long p = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      int k = -1;
      for(int j = 0; j < n; j++) if(pid[j] == p) { k = j; break; }
      if(k < 0)
        {
         k = n++;
         ArrayResize(pid, n); ArrayResize(sym, n); ArrayResize(pnl, n); ArrayResize(volIn, n);
         ArrayResize(entry, n); ArrayResize(sl, n); ArrayResize(closeT, n); ArrayResize(openT, n); ArrayResize(side, n); ArrayResize(closed, n);
         pid[k] = p; sym[k] = HistoryDealGetString(tk, DEAL_SYMBOL); pnl[k] = 0; volIn[k] = 0;
         entry[k] = 0; sl[k] = 0; closeT[k] = 0; openT[k] = 0; side[k] = 0; closed[k] = false;
        }
      long ent = HistoryDealGetInteger(tk, DEAL_ENTRY);
      double comm = HistoryDealGetDouble(tk, DEAL_COMMISSION);
      double fee  = HistoryDealGetDouble(tk, DEAL_FEE);
      pnl[k] += comm + fee;
      if(ent == DEAL_ENTRY_IN)
        {
         if(volIn[k] == 0)
           {
            entry[k] = HistoryDealGetDouble(tk, DEAL_PRICE);
            sl[k]    = HistoryDealGetDouble(tk, DEAL_SL);
            side[k]  = (type == DEAL_TYPE_BUY) ? 0 : 1;
            openT[k] = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
           }
         volIn[k] += HistoryDealGetDouble(tk, DEAL_VOLUME);
        }
      else // OUT, OUT_BY, INOUT
        {
         pnl[k] += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP);
         datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
         if(t > closeT[k]) closeT[k] = t;
         closed[k] = true;
        }
     }

   long offset = (long)(TimeTradeServer() - TimeGMT());   // broker time minus UTC
   string trades = "";
   for(int k = 0; k < n; k++)
     {
      if(!closed[k]) continue;
      string r = "null";
      if(sl[k] > 0 && entry[k] > 0 && volIn[k] > 0)
        {
         double ts = SymbolInfoDouble(sym[k], SYMBOL_TRADE_TICK_SIZE);
         double tv = SymbolInfoDouble(sym[k], SYMBOL_TRADE_TICK_VALUE);
         if(ts > 0 && tv > 0)
           {
            double risk = MathAbs(entry[k] - sl[k]) / ts * tv * volIn[k];
            if(risk > 0) r = DoubleToString(pnl[k] / risk, 2);
           }
        }
      if(trades != "") trades += ",";
      trades += "{\"id\":\"mt5-" + IntegerToString(pid[k]) + "\""
              + ",\"closeUtc\":\"" + IsoUtc(closeT[k] - (datetime)offset) + "\""
              + (openT[k] > 0 ? ",\"openUtc\":\"" + IsoUtc(openT[k] - (datetime)offset) + "\"" : "")
              + ",\"asset\":\"" + sym[k] + "\""
              + ",\"side\":\"" + (side[k] == 0 ? "buy" : "sell") + "\""
              + ",\"volume\":" + DoubleToString(volIn[k], 2)
              + ",\"pnl\":" + DoubleToString(pnl[k], 2)
              + ",\"r\":" + r + "}";
     }

   string acc = "\"account\":{\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
              + ",\"server\":\"" + Esc(AccountInfoString(ACCOUNT_SERVER)) + "\""
              + ",\"company\":\"" + Esc(AccountInfoString(ACCOUNT_COMPANY)) + "\""
              + ",\"currency\":\"" + AccountInfoString(ACCOUNT_CURRENCY) + "\""
              + ",\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)
              + ",\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "}";
   // open positions, with the floating result
   string pos = "";
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      string ps = PositionGetString(POSITION_SYMBOL);
      int dg = (int)SymbolInfoInteger(ps, SYMBOL_DIGITS);
      if(pos != "") pos += ",";
      pos += "{\"id\":\"" + IntegerToString((long)tk) + "\""
           + ",\"asset\":\"" + ps + "\""
           + ",\"side\":\"" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell") + "\""
           + ",\"volume\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)
           + ",\"openUtc\":\"" + IsoUtc((datetime)PositionGetInteger(POSITION_TIME) - (datetime)offset) + "\""
           + ",\"open\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), dg)
           + ",\"price\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), dg)
           + ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), dg)
           + ",\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), dg)
           + ",\"pnl\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP), 2) + "}";
     }

   // contract details of the chart symbol, for the lot calculator
   string spec = "\"symbol\":{\"name\":\"" + _Symbol + "\""
               + ",\"contract\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2)
               + ",\"tickSize\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 8)
               + ",\"tickValue\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 8)
               + ",\"volMin\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 2)
               + ",\"volStep\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), 2)
               + ",\"volMax\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), 2) + "}";

   return acc + "," + spec + ",\"positions\":[" + pos + "],\"trades\":[" + trades + "]";
  }

//+------------------------------------------------------------------+
//| GitHub Gist upload                                               |
//+------------------------------------------------------------------+
bool Upload(const string json)
  {
   string files = "\"files\":{\"" + GIST_FILE + "\":{\"content\":\"" + Esc(json) + "\"}}";
   string body, method, url;
   if(g_gist == "")
     {
      method = "POST"; url = API;
      body = "{\"description\":\"Bullion Monkey MT5\",\"public\":false," + files + "}";
     }
   else
     {
      method = "PATCH"; url = API + "/" + g_gist;
      body = "{" + files + "}";
     }
   string headers = "Authorization: Bearer " + GitHubToken + "\r\n"
                  + "Accept: application/vnd.github+json\r\n"
                  + "User-Agent: BullionMonkeySync\r\n"
                  + "Content-Type: application/json\r\n";
   char data[], result[];
   string resHeaders;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, len - 1);   // drop the trailing zero
   ResetLastError();
   int code = WebRequest(method, url, headers, 15000, data, result, resHeaders);
   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014)
         Alert("Bullion Monkey: https://api.github.com unter Extras > Optionen > Expert Advisors bei WebRequest erlauben.");
      else
         Print("Bullion Monkey: WebRequest Fehler ", err);
      return false;
     }
   string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code == 401) { Alert("Bullion Monkey: GitHub-Token ungültig."); return false; }
   if(code == 404 && g_gist != "") { Print("Bullion Monkey: Gist nicht gefunden: ", g_gist); return false; }
   if(code < 200 || code >= 300) { Print("Bullion Monkey: GitHub antwortet ", code, " ", StringSubstr(resp, 0, 200)); return false; }

   if(g_gist == "")
     {
      g_gist = JsonString(resp, "id");
      if(g_gist != "")
        {
         SaveId(g_gist);
         Alert("Bullion Monkey: Verbunden. Gist-ID für die App: " + g_gist);
        }
     }
   Print("Bullion Monkey: synchronisiert (", g_gist, ")");
   return true;
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string IsoUtc(datetime t)
  {
   MqlDateTime d; TimeToStruct(t, d);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ", d.year, d.mon, d.day, d.hour, d.min, d.sec);
  }

string Esc(const string s)
  {
   string o = s;
   StringReplace(o, "\\", "\\\\");
   StringReplace(o, "\"", "\\\"");
   StringReplace(o, "\r", "");
   StringReplace(o, "\n", "\\n");
   return o;
  }

// value of the first "key":"..." at the top level of a GitHub response
string JsonString(const string json, const string key)
  {
   int p = StringFind(json, "\"" + key + "\"");
   if(p < 0) return "";
   p = StringFind(json, "\"", StringFind(json, ":", p) + 1);
   if(p < 0) return "";
   int e = StringFind(json, "\"", p + 1);
   return (e > p) ? StringSubstr(json, p + 1, e - p - 1) : "";
  }

string ReadSavedId()
  {
   int h = FileOpen(ID_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return "";
   string id = FileReadString(h);
   FileClose(h);
   StringTrimLeft(id); StringTrimRight(id);
   return id;
  }

void SaveId(const string id)
  {
   int h = FileOpen(ID_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, id);
   FileClose(h);
  }
//+------------------------------------------------------------------+
