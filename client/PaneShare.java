import java.io.IOException;
import java.util.ArrayList;


public class PaneShare {


	String _shareName;
	int _maxresv;
	int _minresv = -1;
	Boolean _allow= null; 
	Boolean _deny = null;  
	int _reserveTBCapacity = -1;
	int _reserveTBFill = -1;
	ArrayList<String> _principals;
	PaneShare _parent; //for test and debug purpose
	
	PaneFlowGroup _flowgroup;
	
	PaneClient _client = null;

	public PaneShare(String shareName, int maxresv, PaneFlowGroup fg){
		/*
		 * fg here is the initial flow group of this share, if a null
		 * is given, '*' will be put into the command
		 */
		_shareName = shareName;
		_maxresv = maxresv;
		_principals = new ArrayList<String>();
		_flowgroup = fg;
	}

	
	public String getShareName(){
		return _shareName;
	}
	//---------------------min resv
	public void setMinResv(int minresv){
		_minresv = minresv;
	}

	public boolean isSetMin(){
		return _minresv == -1?false:true;
	}

	public int getMinResv(){
		return _minresv;
	}

	//------------------allow
	public void setAllow(boolean allow){
		_allow = allow == true?Boolean.TRUE:Boolean.FALSE;
	}

	public boolean isSetAllow(){
		return _allow == null?false:true;
	}

	public boolean getAllow(){
		return _allow == Boolean.TRUE?true:false;
	}
	//----------------deny
	public void setDeny(boolean deny){
		_deny = deny == true?Boolean.TRUE:Boolean.FALSE;
	}		


	public boolean isSetDeny(){
		return _deny == null?false:true;
	}

	public boolean getDeny(){
		return _deny == Boolean.TRUE?true:false;
	}	

	//---------------reserveTBCapacity
	public void setReserveTBCapacity(int rtbc){
		_reserveTBCapacity = rtbc;
	}

	public boolean isSetReserveTBCapacity(){
		return _reserveTBCapacity == -1?false:true;
	}

	public int getReserveTBCapacity(){
		return _reserveTBCapacity;
	}
	//---------------reserveTBFill
	public void setReserveTBFill(int rtbf){
		_reserveTBFill = rtbf;
	}

	public boolean isSetReserveTBFill(){
		return _reserveTBFill == -1?false:true;
	}

	public int getReserveTBFill(){
		return _reserveTBFill;
	}
	//-------------------speakers	
	public void removeSpeakers(String spkName){
		_principals.remove(spkName);
	}
	
	public void setClient(PaneClient client){
		_client = client;
	}

	public synchronized String grant(PaneUser user) throws IOException{
		
		_principals.add(user.getName());
		String cmd = "grant " + getShareName() + " to " + user.getName();
		String response = _client.sendAndWait(cmd);
//		if succeeded
//		_speakers.add(user.getName());
//		user.addShare(this);
		return response;
	}	

	public String newShare(PaneShare share) throws IOException{
		
		share.setParent(this);
		String cmd = share.generateCreationCmd();
		share.setClient(_client);
		String response = _client.sendAndWait(cmd);
		return response;
	}
	
	public String reserve(PaneReservation resv) throws IOException{
		
		resv.setParent(this);
		String cmd = resv.generateCmd();
		String response = _client.sendAndWait(cmd);
		return response;
	}
	
	public String allow(PaneAllow allow) throws IOException{
		
		allow.setParent(this);
		String cmd = allow.generateCmd();
		String response = _client.sendAndWait(cmd);
		return response;
	}
	
	public String deny(PaneDeny deny) throws IOException{
		
		deny.setParent(this);
		String cmd = deny.generateCmd();
		String response = _client.sendAndWait(cmd);		
		return response;
	}
	
	
	protected void setParent(PaneShare parent){
		_parent = parent;
	}
	
	protected String generateCreationCmd(){
		
		String fg = "*";
		if (_flowgroup != null)
			fg = _flowgroup.generateConfig();
		
		String cmd = "NewShare " + getShareName() + " for ("+fg+") ";
		cmd += "[reserve <= "+ _maxresv;
		if (_minresv != -1){
			cmd += " reserve >= "+_minresv;
		}
		if (_reserveTBCapacity != -1){
			cmd += " reserveTBCapacity = "+ _reserveTBCapacity;
		}
		if(_reserveTBFill != -1){
			cmd += " reserveTBFill = " + _reserveTBFill;
		}
		cmd += "] on "+ _parent.getShareName();
		return cmd;
		
	}
	
	public String toString(){
		return "PaneShare: " + generateCreationCmd();
	}
}
