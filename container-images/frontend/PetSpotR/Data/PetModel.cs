using Dapr.Client;

namespace PetSpotR.Models 
{
    public class PetModel
    {
        public string Name { get; set; }
        public string Type { get; set; }
        public string Breed { get; set; }
        public string OwnerEmail { get; set; }
        public string ID { get; set; }
        public string State { get; set; }
        public List<string> Images { get; set; }
        //public class QueryResponse<T>
        //{
        //    internal readonly string? id;
        //    internal readonly string? name;
        //    internal readonly string? state;
        //    internal readonly string? type;

        //    public List<T>? Results { get; set; }
        //}

        // Constructor
        public PetModel()
        {
            Name = "";
            Type = "";
            Breed = "";
            OwnerEmail = "";
            ID = Guid.NewGuid().ToString();
            State = "new";
            Images = new();
        }

        public async Task SavePetStateAsync(DaprClient daprClient, string storeName)
        {
            try {
                await daprClient.SaveStateAsync(
                    storeName: storeName,
                    key: ID,
                    value: this
                );
            } catch {
                throw;
            }

            return;
        }

        public async Task PublishLostPetAsync(DaprClient daprClient, string pubsubName)
        {
            try {
                await daprClient.PublishEventAsync(
                    pubsubName: pubsubName,
                    topicName: "lostPet",
                    data: new Dictionary<string, string>
                    {
                        { "petId", ID }
                    }
                );
            } catch {
                throw;
            }

            return;
        }

        public static async Task<IEnumerable<PetModel>> GetPetStateAsync(DaprClient daprClient, string storeName)
        {
            try
            {
                // Retrieve all state entries from the state store
                var queryRequest = "{\"query\": \"SELECT * FROM c\"}";
                var stateEntries = await daprClient.QueryStateAsync<PetModel>(storeName, queryRequest);

                // Filter and map the state entries to PetModel objects
                return stateEntries.Results.Select(p => p.Data);
            }
            catch
            {
                throw;
            }
        }
    }
}
