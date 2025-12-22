echo "Running script to generate architecture diagram from compose..."

#For generating architecture diagram with networks, ports and volumes
if
  docker run --rm -it --name bahpkg -v ${PWD}:/input pmsipilot/docker-compose-viz:latest  render -m image --force bahmni-lite/compose.yml --output-file=architecture-diagram/bahmni-lite-architecture-diagram.png $1 $2 $3

  docker run --rm -it --name bahpkg -v ${PWD}:/input pmsipilot/docker-compose-viz:latest  render -m image --force bahmni-standard/compose.yml --output-file=architecture-diagram/bahmni-standard-architecture-diagram.png $1 $2 $3
then
  echo "Successfully generated architecture diagram from compose!"
else
  echo "Failed to generate architecture diagram from compose!"
fi
