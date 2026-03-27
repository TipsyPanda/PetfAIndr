#Version: 1.0
#Description: This is the main application file for the PetfAIndr backend. It is a Python Flask application that listens for Dapr pub/sub messages for lost and found pets.
from flask import Flask, request, jsonify
from cloudevents.http import from_http
import json
import os
from dapr.clients import DaprClient
from petspotr import pet
import requests
import time
from concurrent.futures import ThreadPoolExecutor

app = Flask(__name__)
app_port = os.getenv('APP_PORT', '5000')

# Azure Custom Vision API details, provided through K8s secrets as environment variables
storage_account_name = os.getenv('STORAGE_ACCOUNT_NAME')   
training_endpoint = os.getenv('CVAPI_TRAINING_ENDPOINT')
training_key = os.getenv('CVAPI_TRAINING_KEY')
prediction_endpoint = os.getenv('CVAPI_PREDICTION_ENDPOINT')
prediction_key = os.getenv('CVAPI_PREDICTION_KEY')
project_id = os.getenv('CVAPI_PROJECT_ID')
prediction_resource_id = os.getenv('CVAPI_PREDICTION_RESOURCE_ID')
iteration_publish_name = "publishediteration"

dapr = DaprClient()

statestore = 'pets'
pubsubbroker = 'pubsub'

# Create a thread pool executor
executor = ThreadPoolExecutor(max_workers=10)

# Register Dapr pub/sub subscriptions
@app.route('/dapr/subscribe', methods=['GET'])
def subscribe():
    subscriptions = [
        {
            'pubsubname': pubsubbroker,
            'topic': 'lostPet',
            'route': 'lostPet'
        },
        {
            'pubsubname': pubsubbroker,
            'topic': 'foundPet',
            'route': 'foundPet'
        }
    ]
    print('Dapr pub/sub is subscribed to: ' + json.dumps(subscriptions))
    return jsonify(subscriptions)

def process_lost_pet(event):
    id = event.data['petId']

    # Get pet details from Dapr state store (e.g. Azure Cosmos DB)
    try: 
        result = dapr.get_state(store_name=statestore, key=id)
        data = json.loads(result.data)
        current_time_str = time.strftime("%H:%M:%S", time.localtime())
        print(f'{current_time_str}: New lost Pet information retrieved', flush=True)
    except Exception as e:
        print(f'Error: {e}', flush=True)
        return

    p = pet(
            data['id'],
            data['name'],
            data['type'],
            data['breed'],
            data['images'],
            data['state'],
            data['ownerEmail']
        )
    
    ### Create the REST Call to the Custom Vision API for creating the tag, upload the images and tag them, train the model and publish this iteration of the model
    ### Create the tag for the lost pet through the Custom Vision API
    headerss = {
                    "Content-Type": "application/json",
                    "Training-Key": training_key
                }
    tag_name = id #The Tag Name needs to be the ID of the the DB-Entry, otherwise the right entry can´t be found if a match is found of a seen pet.
    detailed_url = training_endpoint + "customvision/v3.3/training/projects/" +project_id + "/tags?name=" + tag_name
    # Send the POST request to Azure Custom Vision API for creating the tag
    try:
         response = requests.post(detailed_url, headers=headerss)
         response.raise_for_status() # Raise an exception for 4xx/5xx responses - for 200 OK, the code will continue
         print(f'Successfully created the tag with Tag-ID ' + response.json()['id'] + ' and name (as cosmos db entry id) ' + response.json()['name'], flush=True)
         tag_id = response.json()['id']
    except requests.exceptions.RequestException as e:
          print(f'Error sending data to Azure Custom Vision: {e}', flush=True)
          return

    ### Add Images to the newly created tag
    detailed_url = training_endpoint + "customvision/v3.3/training/projects/" +project_id + "/images/urls"

    for image in p.Images:
        rest_body = {
            "images": [{"url": "https://" + storage_account_name + ".blob.core.windows.net/images/" + image}],
            "tagIds": [tag_id]
                }   
        # Send the POST request to Azure Custom Vision API
        try:
            response = requests.post(detailed_url, headers=headerss, json=rest_body)
            response.raise_for_status() # Raise an exception for 4xx/5xx responses - for 200 OK, the code will continue
            print(f'Successfully added image {image} to the tag with id {tag_id}', flush=True)
        except requests.exceptions.RequestException as e:
            print(f'Error sending data to Azure Custom Vision: {e}', flush=True)
            return

    ### Train the model and get the iteration ID
    current_time_str = time.strftime("%H:%M:%S", time.localtime())
    print(f'{current_time_str}: Waiting for 30 sec. until the uploaded images are correctly tagged and referenced in the Custom Vision Service ...', flush=True)
    time.sleep(30)
    detailed_url = training_endpoint + "customvision/v3.3/training/projects/" +project_id + "/train?forceTrain=true"
    # Send the POST request to Azure Custom Vision
    try:
        response = requests.post(detailed_url, headers=headerss)
        response.raise_for_status() # Raise an exception for 4xx/5xx responses - for 200 OK, the code will continue
        print(f'Successfully started a new training iteration of the model with the new set of images!', flush=True)
        iteration_id = response.json()['id']
        #store the iteration id for later usage in the DB
        db_iteration_id = { "id": iteration_id }
    except requests.exceptions.RequestException as e:
            print(f'Error sending data to Azure Custom Vision: {e}', flush=True)
            return

    ### Wait until the new iteration is trained
    current_time_str = time.strftime("%H:%M:%S", time.localtime())
    print(f'{current_time_str}: Waiting for 10 Min. (divided in 2 steps) until the model has been trained with the new images and can be published ...', flush=True)
    time.sleep(300)
    current_time_str = time.strftime("%H:%M:%S", time.localtime())
    print(f'{current_time_str}: 2nd of 2 wait cycles started', flush=True)
    time.sleep(300)
    current_time_str = time.strftime("%H:%M:%S", time.localtime())
    print(f'{current_time_str}: End of the waiting cycle', flush=True)
    
    #Check for published iterations and delete them
    try:
        result = dapr.get_state(store_name=statestore, key="published_db_iteration_id")
                
        if result.data:
            data = json.loads(result.data)
            last_published_iteration_id = data['id']
            detailed_url = training_endpoint + "customvision/v3.3/training/projects/" +project_id + "/iterations/" + last_published_iteration_id + "/publish"
            # Send the POST request to Azure Custom Vision
            response = requests.delete(detailed_url, headers=headerss)
            response.raise_for_status() # Raise an exception for 4xx/5xx responses - for 200 OK, the code will continue
            print(f'Successfully unpublished iteration with ID: {last_published_iteration_id} ', flush=True)
        else:
             print(f'No published iteration ID found in the state store.', flush=True)
        
    except requests.exceptions.RequestException as e:
        print(f'Multiple reasons for this error - Maybe due to a not existing Entry in the DB, or the iteration could not be unpublished. More insights see, error: {e}', flush=True)
        return
    
    ### Publish the new iteration and save the new iteration id in the state store
    detailed_url = training_endpoint + "customvision/v3.3/training/projects/" +project_id + "/iterations/" + iteration_id + "/publish?publishName=" + iteration_publish_name + "&predictionId=" + prediction_resource_id
    # Send the POST request to Azure Custom Vision
    try:
        response = requests.post(detailed_url, headers=headerss)
        response.raise_for_status() # Raise an exception for 4xx/5xx responses - for 200 OK, the code will continue
        current_time_str = time.strftime("%H:%M:%S", time.localtime())
        print(f'{current_time_str}: Successfully published the model with the name {iteration_publish_name}!', flush=True)
        dapr.save_state(store_name=statestore, key="published_db_iteration_id", value=json.dumps(db_iteration_id))
        current_time_str = time.strftime("%H:%M:%S", time.localtime())
        print(f'{current_time_str}: Successfully saved the new published iteration id -{iteration_id}- to the state store.', flush=True)
    except requests.exceptions.RequestException as e:
        print(f'Error sending data to Azure Custom Vision: {e}', flush=True)

@app.route('/lostPet', methods=['POST'])
def lostPet():
    # Get Dapr pub/sub message
    event = from_http(request.headers, request.get_data())
    
    # Acknowledge the message immediately
    executor.submit(process_lost_pet, event)
    return json.dumps({'success': True}), 200, {'ContentType': 'application/json'}

def process_found_pet(event):
    imagename = event.data['imagePath']
    #Call the Custom Vision API Prediction endpoint to see if there is a match - Match is a probability of at 70% 
    detailed_url = prediction_endpoint + "customvision/v3.0/Prediction/" + project_id + "/classify/iterations/" + iteration_publish_name + "/url?store=false"
    headerss = {
        "Content-Type": "application/json",
        "Prediction-Key": prediction_key
    }

    print(f'Checking if image {imagename} has a match in the model ...' , flush=True)
    rest_body = {"url": "https://" + storage_account_name + ".blob.core.windows.net/images/" + imagename}
     # Send the POST request to Azure Custom Vision Prediction API to get the prediction if the provided image of the pet is in the DB.
    try:
        response = requests.post(detailed_url, headers=headerss, json=rest_body)
        response.raise_for_status() # Raise an exception for 4xx/5xx responses - for 200 OK, the code will continue
        print(f'Successfully connected the prediction API to validate {imagename}.', flush=True)
        for prediction in response.json()['predictions']:
            if prediction['probability'] > 0.7:
                print(f'Found a match for {imagename} with tagid-name ' + prediction['tagName'] +' and a probability of ' + str(prediction['probability']), flush=True)
                # Update the state store with the found pet details
                try:
                    # Set the status to found - the key in the DB is the id which is stored in the tagname - THIS architectural design makes it work to update the correct entry in the DB
                    # Retrieve the current state
                    result = dapr.get_state(store_name=statestore, key=prediction['tagName'])
                    current_state = json.loads(result.data)

                    # Update the state value
                    current_state['state'] = 'found'

                    # Save the updated state back to the state store
                    dapr.save_state(store_name=statestore, key=prediction['tagName'], value=json.dumps(current_state))
                    print(f'Successfully updated the state store for petId ' + prediction['tagName'], flush=True)
                except Exception as e:
                    print(f'Error updating state store: {e}', flush=True)
    except requests.exceptions.RequestException as e:
        print(f'Error sending data to Azure Custom Vision: {e}', flush=True)

@app.route('/foundPet', methods=['POST'])
def foundPet():
    event = from_http(request.headers, request.get_data())
    
    # Acknowledge the message immediately
    executor.submit(process_found_pet, event)
    return json.dumps({'success': True}), 200, {'ContentType': 'application/json'}

@app.route('/', methods=['GET'])
def index():
    return '<h1>PetfAIndr Backend</h1>'

app.run(port=app_port)