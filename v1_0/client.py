from novaclient import client
import accounts
import backup_schedules
import flavors
import images
import ipgroups
import servers
import zones


class Client(object):
    """
    Top-level object to access the OpenStack Compute API.

    Create an instance with your creds::

        >>> client = Client(USERNAME, PASSWORD, PROJECT_ID, AUTH_URL)

    Then call methods on its managers::

        >>> client.servers.list()
        ...
        >>> client.flavors.list()
        ...

    """

    def __init__(self, username, api_key, project_id, auth_url=None,
                 insecure=False, timeout=None, token=None, region_name=None,
                 endpoint_name=None, extensions=None, service_type=None,
                 service_name=None, endpoint_type='publicURL'):

        # FIXME(comstud): Rename the api_key argument above when we
        # know it's not being used as keyword argument
        password = api_key
        self.accounts = accounts.AccountManager(self)
        self.backup_schedules = backup_schedules.BackupScheduleManager(self)
        self.flavors = flavors.FlavorManager(self)
        self.images = images.ImageManager(self)
        self.ipgroups = ipgroups.IPGroupManager(self)
        self.servers = servers.ServerManager(self)
        self.zones = zones.ZoneManager(self)
        #service_type is unused in v1_0
        #service_name is unused in v1_0
        #endpoint_name is unused in v_10
        #endpoint_type was endpoint_name

        # Add in any extensions...
        if extensions:
            for (ext_name, ext_manager_class, ext_module) in extensions:
                setattr(self, ext_name, ext_manager_class(self))

        _auth_url = auth_url or 'https://auth.api.rackspacecloud.com/v1.0'

        self.client = client.HTTPClient(username,
                                        password,
                                        project_id,
                                        _auth_url,
                                        insecure=insecure,
                                        timeout=timeout,
                                        proxy_token=token,
                                        region_name=region_name,
                                        endpoint_type=endpoint_type)

    def authenticate(self):
        """
        Authenticate against the server.

        Normally this is called automatically when you first access the API,
        but you can call this method to force authentication right now.

        Returns on success; raises :exc:`exceptions.Unauthorized` if the
        credentials are wrong.
        """
        self.client.authenticate()
